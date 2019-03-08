{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE RecordWildCards #-}

#ifdef USE_GIT_INFO
{-# LANGUAGE TemplateHaskell #-}
#endif

-- | Main stack tool entry point.

module Main (main) where

#ifndef HIDE_DEP_VERSIONS
import qualified Build_stack
#endif
import           Stack.Prelude hiding (Display (..))
import           Control.Monad.Reader (local)
import           Control.Monad.Trans.Except (ExceptT)
import           Control.Monad.Writer.Lazy (Writer)
import           Data.Attoparsec.Args (parseArgs, EscapingMode (Escaping))
import           Data.Attoparsec.Interpreter (getInterpreterArgs)
import qualified Data.ByteString.Lazy as L
import           Data.List
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Text as T
import           Data.Version (showVersion)
import           RIO.Process
#ifdef USE_GIT_INFO
import           GitHash (giCommitCount, giHash, tGitInfoCwdTry)
#endif
import           Distribution.System (buildArch)
import qualified Distribution.Text as Cabal (display)
import           Distribution.Version (mkVersion')
import           GHC.IO.Encoding (mkTextEncoding, textEncodingName)
import           Lens.Micro ((?~))
import           Options.Applicative
import           Options.Applicative.Help (errorHelp, stringChunk, vcatChunks)
import           Options.Applicative.Builder.Extra
import           Options.Applicative.Complicated
#ifdef USE_GIT_INFO
import           Options.Applicative.Simple (simpleVersion)
#endif
import           Options.Applicative.Types (ParserHelp(..))
import           Path
import           Path.IO
import qualified Paths_stack as Meta
import           RIO.PrettyPrint
import qualified RIO.PrettyPrint as PP (style)
import           Stack.Build
import           Stack.Build.Target (NeedTargets(..))
import           Stack.Clean (CleanOpts(..), clean)
import           Stack.Config
import           Stack.ConfigCmd as ConfigCmd
import           Stack.Constants
import           Stack.Constants.Config
import           Stack.Coverage
import qualified Stack.Docker as Docker
import           Stack.Dot
import           Stack.GhcPkg (findGhcPkgField)
import qualified Stack.Nix as Nix
import           Stack.FileWatch
import           Stack.Freeze
import           Stack.Ghci
import           Stack.Hoogle
import           Stack.Ls
import qualified Stack.IDE as IDE
import qualified Stack.Image as Image
import           Stack.Init
import           Stack.New
import           Stack.Options.BuildParser
import           Stack.Options.CleanParser
import           Stack.Options.DockerParser
import           Stack.Options.DotParser
import           Stack.Options.ExecParser
import           Stack.Options.GhciParser
import           Stack.Options.GlobalParser
import           Stack.Options.FreezeParser

import           Stack.Options.HpcReportParser
import           Stack.Options.NewParser
import           Stack.Options.NixParser
import           Stack.Options.ScriptParser
import           Stack.Options.SDistParser
import           Stack.Options.SolverParser
import           Stack.Options.Utils
import qualified Stack.Path
import           Stack.Runners
import           Stack.Script
import           Stack.SDist (getSDistTarball, checkSDistTarball, checkSDistTarball', SDistOpts(..))
import           Stack.Setup (withNewLocalBuildTargets)
import           Stack.SetupCmd
import qualified Stack.Sig as Sig
import           Stack.Snapshot (loadResolver)
import           Stack.Solver (solveExtraDeps)
import           Stack.Types.Version
import           Stack.Types.Config
import           Stack.Types.Compiler
import           Stack.Types.NamedComponent
import           Stack.Types.Nix
import           Stack.Types.SourceMap
import           Stack.Unpack
import           Stack.Upgrade
import qualified Stack.Upload as Upload
import qualified System.Directory as D
import           System.Environment (getProgName, getArgs, withArgs)
import           System.Exit
import           System.FilePath (isValid, pathSeparator, takeDirectory)
import qualified System.FilePath as FP
import           System.IO (stderr, stdin, stdout, BufferMode(..), hPutStrLn, hGetEncoding, hSetEncoding)
import           System.Terminal (hIsTerminalDeviceOrMinTTY)

-- | Change the character encoding of the given Handle to transliterate
-- on unsupported characters instead of throwing an exception
hSetTranslit :: Handle -> IO ()
hSetTranslit h = do
    menc <- hGetEncoding h
    case fmap textEncodingName menc of
        Just name
          | '/' `notElem` name -> do
              enc' <- mkTextEncoding $ name ++ "//TRANSLIT"
              hSetEncoding h enc'
        _ -> return ()

versionString' :: String
#ifdef USE_GIT_INFO
versionString' = concat $ concat
    [ [$(simpleVersion Meta.version)]
      -- Leave out number of commits for --depth=1 clone
      -- See https://github.com/commercialhaskell/stack/issues/792
    , case giCommitCount <$> $$tGitInfoCwdTry of
        Left _ -> []
        Right 1 -> []
        Right count -> [" (", show count, " commits)"]
    , [" ", Cabal.display buildArch]
    , [depsString, warningString]
    ]
#else
versionString' =
    showVersion Meta.version
    ++ ' ' : Cabal.display buildArch
    ++ depsString
    ++ warningString
#endif
  where
#ifdef HIDE_DEP_VERSIONS
    depsString = " hpack-" ++ VERSION_hpack
#else
    depsString = "\nCompiled with:\n" ++ unlines (map ("- " ++) Build_stack.deps)
#endif
#ifdef SUPPORTED_BUILD
    warningString = ""
#else
    warningString = unlines
      [ ""
      , "Warning: this is an unsupported build that may use different versions of"
      , "dependencies and GHC than the officially released binaries, and therefore may"
      , "not behave identically.  If you encounter problems, please try the latest"
      , "official build by running 'stack upgrade --force-download'."
      ]
#endif

main :: IO ()
main = do
  -- Line buffer the output by default, particularly for non-terminal runs.
  -- See https://github.com/commercialhaskell/stack/pull/360
  hSetBuffering stdout LineBuffering
  hSetBuffering stdin  LineBuffering
  hSetBuffering stderr LineBuffering
  hSetTranslit stdout
  hSetTranslit stderr
  args <- getArgs
  progName <- getProgName
  isTerminal <- hIsTerminalDeviceOrMinTTY stdout
  -- On Windows, where applicable, defaultColorWhen has the side effect of
  -- enabling ANSI for ANSI-capable native (ConHost) terminals, if not already
  -- ANSI-enabled.
  execExtraHelp args
                Docker.dockerHelpOptName
                (dockerOptsParser False)
                ("Only showing --" ++ Docker.dockerCmdName ++ "* options.")
  execExtraHelp args
                Nix.nixHelpOptName
                (nixOptsParser False)
                ("Only showing --" ++ Nix.nixCmdName ++ "* options.")

  currentDir <- D.getCurrentDirectory
  eGlobalRun <- try $ commandLineHandler currentDir progName False
  case eGlobalRun of
    Left (exitCode :: ExitCode) ->
      throwIO exitCode
    Right (globalMonoid,run) -> do
      global <- globalOptsFromMonoid isTerminal globalMonoid
      when (globalLogLevel global == LevelDebug) $ hPutStrLn stderr versionString'
      case globalReExecVersion global of
          Just expectVersion -> do
              expectVersion' <- parseVersionThrowing expectVersion
              unless (checkVersion MatchMinor expectVersion' (mkVersion' Meta.version))
                  $ throwIO $ InvalidReExecVersion expectVersion (showVersion Meta.version)
          _ -> return ()
      withRunner global $ run `catch` \e ->
          -- This special handler stops "stack: " from being printed before the
          -- exception
          case fromException e of
              Just ec -> liftIO $ exitWith ec
              Nothing -> do
                  logError $ displayShow e
                  liftIO exitFailure

-- Vertically combine only the error component of the first argument with the
-- error component of the second.
vcatErrorHelp :: ParserHelp -> ParserHelp -> ParserHelp
vcatErrorHelp h1 h2 = h2 { helpError = vcatChunks [helpError h2, helpError h1] }

commandLineHandler
  :: FilePath
  -> String
  -> Bool
  -> IO (GlobalOptsMonoid, RIO Runner ())
commandLineHandler currentDir progName isInterpreter = complicatedOptions
  (mkVersion' Meta.version)
  (Just versionString')
  VERSION_hpack
  "stack - The Haskell Tool Stack"
  ""
  "stack's documentation is available at https://docs.haskellstack.org/"
  (globalOpts OuterGlobalOpts)
  (Just failureCallback)
  addCommands
  where
    failureCallback f args =
      case stripPrefix "Invalid argument" (fst (renderFailure f "")) of
          Just _ -> if isInterpreter
                    then parseResultHandler args f
                    else secondaryCommandHandler args f
                        >>= interpreterHandler currentDir args
          Nothing -> parseResultHandler args f

    parseResultHandler args f =
      if isInterpreter
      then do
        let hlp = errorHelp $ stringChunk
              (unwords ["Error executing interpreter command:"
                        , progName
                        , unwords args])
        handleParseResult (overFailure (vcatErrorHelp hlp) (Failure f))
      else handleParseResult (Failure f)

    addCommands = do
      unless isInterpreter (do
        addBuildCommand' "build"
                         "Build the package(s) in this directory/configuration"
                         buildCmd
                         (buildOptsParser Build)
        addBuildCommand' "install"
                         "Shortcut for 'build --copy-bins'"
                         buildCmd
                         (buildOptsParser Install)
        addCommand' "uninstall"
                    "DEPRECATED: This command performs no actions, and is present for documentation only"
                    uninstallCmd
                    (many $ strArgument $ metavar "IGNORED")
        addBuildCommand' "test"
                         "Shortcut for 'build --test'"
                         buildCmd
                         (buildOptsParser Test)
        addBuildCommand' "bench"
                         "Shortcut for 'build --bench'"
                         buildCmd
                         (buildOptsParser Bench)
        addBuildCommand' "haddock"
                         "Shortcut for 'build --haddock'"
                         buildCmd
                         (buildOptsParser Haddock)
        addCommand' "new"
         (unwords [ "Create a new project from a template."
                  , "Run `stack templates' to see available templates."
                  , "Note: you can also specify a local file or a"
                  , "remote URL as a template."
                  ] )
                    newCmd
                    newOptsParser
        addCommand' "templates"
         (unwords [ "List the templates available for `stack new'."
                  , "Templates are drawn from"
                  , "https://github.com/commercialhaskell/stack-templates"
                  , "Note: `stack new' can also accept a template from a"
                  , "local file or a remote URL."
                  ] )
                    templatesCmd
                    (pure ())
        addCommand' "init"
                    "Create stack project config from cabal or hpack package specifications"
                    initCmd
                    initOptsParser
        addCommand' "solver"
                    "Add missing extra-deps to stack project config"
                    solverCmd
                    solverOptsParser
        addCommand' "setup"
                    "Get the appropriate GHC for your project"
                    setupCmd
                    setupParser
        addCommand' "path"
                    "Print out handy path information"
                    pathCmd
                    Stack.Path.pathParser
        addCommand' "ls"
                    "List command. (Supports snapshots, dependencies and stack's styles)"
                    lsCmd
                    lsParser
        addCommand' "unpack"
                    "Unpack one or more packages locally"
                    unpackCmd
                    ((,) <$> some (strArgument $ metavar "PACKAGE")
                         <*> optional (textOption $ long "to" <>
                                         help "Optional path to unpack the package into (will unpack into subdirectory)"))
        addCommand' "update"
                    "Update the package index"
                    updateCmd
                    (pure ())
        addCommand' "upgrade"
                    "Upgrade to the latest stack"
                    upgradeCmd
                    upgradeOpts
        addCommand'
            "upload"
            "Upload a package to Hackage"
            uploadCmd
            (sdistOptsParser True)
        addCommand'
            "sdist"
            "Create source distribution tarballs"
            sdistCmd
            (sdistOptsParser False)
        addCommand' "dot"
                    "Visualize your project's dependency graph using Graphviz dot"
                    dotCmd
                    (dotOptsParser False) -- Default for --external is False.
        addCommand' "ghc"
                    "Run ghc"
                    execCmd
                    (execOptsParser $ Just ExecGhc)
        addCommand' "hoogle"
                    ("Run hoogle, the Haskell API search engine. Use 'stack exec' syntax " ++
                     "to pass Hoogle arguments, e.g. stack hoogle -- --count=20")
                    hoogleCmd
                    ((,,,) <$> many (strArgument (metavar "ARG"))
                          <*> boolFlags
                                  True
                                  "setup"
                                  "If needed: install hoogle, build haddocks and generate a hoogle database"
                                  idm
                          <*> switch
                                  (long "rebuild" <>
                                   help "Rebuild the hoogle database")
                          <*> switch
                                  (long "server" <>
                                   help "Start local Hoogle server"))
        )

      -- These are the only commands allowed in interpreter mode as well
      addCommand' "exec"
                  "Execute a command"
                  execCmd
                  (execOptsParser Nothing)
      addCommand' "run"
                  "Build and run an executable. Defaults to the first available executable if none is provided as the first argument."
                  execCmd
                  (execOptsParser $ Just ExecRun)
      addGhciCommand' "ghci"
                      "Run ghci in the context of package(s) (experimental)"
                      ghciCmd
                      ghciOptsParser
      addGhciCommand' "repl"
                      "Run ghci in the context of package(s) (experimental) (alias for 'ghci')"
                      ghciCmd
                      ghciOptsParser
      addCommand' "runghc"
                  "Run runghc"
                  execCmd
                  (execOptsParser $ Just ExecRunGhc)
      addCommand' "runhaskell"
                  "Run runghc (alias for 'runghc')"
                  execCmd
                  (execOptsParser $ Just ExecRunGhc)
      addCommand "script"
                 "Run a Stack Script"
                 globalFooter
                 scriptCmd
                 (\so gom ->
                    gom
                      { globalMonoidResolverRoot = First $ Just $ takeDirectory $ soFile so
                      })
                 (globalOpts OtherCmdGlobalOpts)
                 scriptOptsParser
      addCommand' "freeze"
                  "Show project or snapshot with pinned dependencies if there are any such"
                  freezeCmd
                  freezeOptsParser

      unless isInterpreter (do
        addCommand' "eval"
                    "Evaluate some haskell code inline. Shortcut for 'stack exec ghc -- -e CODE'"
                    evalCmd
                    (evalOptsParser "CODE")
        addCommand' "clean"
                    "Clean the local packages"
                    cleanCmd
                    cleanOptsParser
        addCommand' "list-dependencies"
                    "List the dependencies"
                    (listDependenciesCmd True)
                    listDepsOptsParser
        addCommand' "query"
                    "Query general build information (experimental)"
                    queryCmd
                    (many $ strArgument $ metavar "SELECTOR...")
        addSubCommands'
            "ide"
            "IDE-specific commands"
            (let outputFlag = flag
                   IDE.OutputLogInfo
                   IDE.OutputStdout
                   (long "stdout" <>
                    help "Send output to stdout instead of the default, stderr")
                 cabalFileFlag = flag
                   IDE.ListPackageNames
                   IDE.ListPackageCabalFiles
                   (long "cabal-files" <>
                    help "Print paths to package cabal-files instead of package names")
             in
             do addCommand'
                    "packages"
                    "List all available local loadable packages"
                    idePackagesCmd
                    ((,) <$> outputFlag <*> cabalFileFlag)
                addCommand'
                    "targets"
                    "List all available stack targets"
                    ideTargetsCmd
                    outputFlag)
        addSubCommands'
          Docker.dockerCmdName
          "Subcommands specific to Docker use"
          (do addCommand' Docker.dockerPullCmdName
                          "Pull latest version of Docker image from registry"
                          dockerPullCmd
                          (pure ())
              addCommand' "reset"
                          "Reset the Docker sandbox"
                          dockerResetCmd
                          (switch (long "keep-home" <>
                                   help "Do not delete sandbox's home directory"))
              addCommand' Docker.dockerCleanupCmdName
                          "Clean up Docker images and containers"
                          dockerCleanupCmd
                          dockerCleanupOptsParser)
        addSubCommands'
            ConfigCmd.cfgCmdName
            "Subcommands specific to modifying stack.yaml files"
            (addCommand' ConfigCmd.cfgCmdSetName
                        "Sets a field in the project's stack.yaml to value"
                        cfgSetCmd
                        configCmdSetParser)
        addSubCommands'
            Image.imgCmdName
            "Subcommands specific to imaging"
            (addCommand'
                 Image.imgDockerCmdName
                 "Build a Docker image for the project"
                 imgDockerCmd
                 ((,) <$>
                  boolFlags
                      True
                      "build"
                      "building the project before creating the container"
                      idm <*>
                  many
                      (textOption
                           (long "image" <>
                            help "A specific container image name to build"))))
        addSubCommands'
          "hpc"
          "Subcommands specific to Haskell Program Coverage"
          (addCommand' "report"
                        "Generate unified HPC coverage report from tix files and project targets"
                        hpcReportCmd
                        hpcReportOptsParser)
        )
      where
        -- addCommand hiding global options
        addCommand' :: String -> String -> (a -> RIO Runner ()) -> Parser a
                    -> AddCommand
        addCommand' cmd title constr =
            addCommand cmd title globalFooter constr (\_ gom -> gom) (globalOpts OtherCmdGlobalOpts)

        addSubCommands' :: String -> String -> AddCommand
                        -> AddCommand
        addSubCommands' cmd title =
            addSubCommands cmd title globalFooter (globalOpts OtherCmdGlobalOpts)

        -- Additional helper that hides global options and shows build options
        addBuildCommand' :: String -> String -> (a -> RIO Runner ()) -> Parser a
                         -> AddCommand
        addBuildCommand' cmd title constr =
            addCommand cmd title globalFooter constr (\_ gom -> gom) (globalOpts BuildCmdGlobalOpts)

        -- Additional helper that hides global options and shows some ghci options
        addGhciCommand' :: String -> String -> (a -> RIO Runner ()) -> Parser a
                         -> AddCommand
        addGhciCommand' cmd title constr =
            addCommand cmd title globalFooter constr (\_ gom -> gom) (globalOpts GhciCmdGlobalOpts)

    globalOpts :: GlobalOptsContext -> Parser GlobalOptsMonoid
    globalOpts kind =
        extraHelpOption hide progName (Docker.dockerCmdName ++ "*") Docker.dockerHelpOptName <*>
        extraHelpOption hide progName (Nix.nixCmdName ++ "*") Nix.nixHelpOptName <*>
        globalOptsParser currentDir kind
            (if isInterpreter
                -- Silent except when errors occur - see #2879
                then Just LevelError
                else Nothing)
        where hide = kind /= OuterGlobalOpts

    globalFooter = "Run 'stack --help' for global options that apply to all subcommands."

type AddCommand =
    ExceptT (RIO Runner ()) (Writer (Mod CommandFields (RIO Runner (), GlobalOptsMonoid))) ()

-- | fall-through to external executables in `git` style if they exist
-- (i.e. `stack something` looks for `stack-something` before
-- failing with "Invalid argument `something'")
secondaryCommandHandler
  :: [String]
  -> ParserFailure ParserHelp
  -> IO (ParserFailure ParserHelp)
secondaryCommandHandler args f =
    -- don't even try when the argument looks like a path or flag
    if elem pathSeparator cmd || "-" `isPrefixOf` head args
       then return f
    else do
      mExternalExec <- D.findExecutable cmd
      case mExternalExec of
        Just ex -> withProcessContextNoLogging $ do
          -- TODO show the command in verbose mode
          -- hPutStrLn stderr $ unwords $
          --   ["Running", "[" ++ ex, unwords (tail args) ++ "]"]
          _ <- exec ex (tail args)
          return f
        Nothing -> return $ fmap (vcatErrorHelp (noSuchCmd cmd)) f
  where
    -- FIXME this is broken when any options are specified before the command
    -- e.g. stack --verbosity silent cmd
    cmd = stackProgName ++ "-" ++ head args
    noSuchCmd name = errorHelp $ stringChunk
      ("Auxiliary command not found in path `" ++ name ++ "'")

interpreterHandler
  :: Monoid t
  => FilePath
  -> [String]
  -> ParserFailure ParserHelp
  -> IO (GlobalOptsMonoid, (RIO Runner (), t))
interpreterHandler currentDir args f = do
  -- args can include top-level config such as --extra-lib-dirs=... (set by
  -- nix-shell) - we need to find the first argument which is a file, everything
  -- afterwards is an argument to the script, everything before is an argument
  -- to Stack
  (stackArgs, fileArgs) <- spanM (fmap not . D.doesFileExist) args
  case fileArgs of
    (file:fileArgs') -> runInterpreterCommand file stackArgs fileArgs'
    [] -> parseResultHandler (errorCombine (noSuchFile firstArg))
  where
    firstArg = head args

    spanM _ [] = return ([], [])
    spanM p xs@(x:xs') = do
      r <- p x
      if r
      then do
        (ys, zs) <- spanM p xs'
        return (x:ys, zs)
      else
        return ([], xs)

    -- if the first argument contains a path separator then it might be a file,
    -- or a Stack option referencing a file. In that case we only show the
    -- interpreter error message and exclude the command related error messages.
    errorCombine =
      if pathSeparator `elem` firstArg
      then overrideErrorHelp
      else vcatErrorHelp

    overrideErrorHelp h1 h2 = h2 { helpError = helpError h1 }

    parseResultHandler fn = handleParseResult (overFailure fn (Failure f))
    noSuchFile name = errorHelp $ stringChunk
      ("File does not exist or is not a regular file `" ++ name ++ "'")

    runInterpreterCommand path stackArgs fileArgs = do
      progName <- getProgName
      iargs <- getInterpreterArgs path
      let parseCmdLine = commandLineHandler currentDir progName True
          -- Implicit file arguments are put before other arguments that
          -- occur after "--". See #3658
          cmdArgs = stackArgs ++ case break (== "--") iargs of
            (beforeSep, []) -> beforeSep ++ ["--"] ++ [path] ++ fileArgs
            (beforeSep, optSep : afterSep) ->
              beforeSep ++ [optSep] ++ [path] ++ fileArgs ++ afterSep
       -- TODO show the command in verbose mode
       -- hPutStrLn stderr $ unwords $
       --   ["Running", "[" ++ progName, unwords cmdArgs ++ "]"]
      (a,b) <- withArgs cmdArgs parseCmdLine
      return (a,(b,mempty))

pathCmd :: [Text] -> RIO Runner ()
pathCmd = Stack.Path.path goWithout goWith
  where
    goWithout go = go & globalOptsBuildOptsMonoidL . buildOptsMonoidHaddockL ?~ False
    goWith go = go & globalOptsBuildOptsMonoidL . buildOptsMonoidHaddockL ?~ True


setupCmd :: SetupCmdOpts -> RIO Runner ()
setupCmd sco@SetupCmdOpts{..} =
  withLoadConfig $
  withActualBuildConfigAndLock $ \lk -> do

    -- FIXME time to just rip off the bandaid and kill UpgradeCabal
    nixEnabled <- view $ configL.to (nixEnable . configNix)
    when (isJust scoUpgradeCabal && nixEnabled) $ throwIO UpgradeCabalUnusable

    compilerVersion <- view wantedCompilerVersionL
    projectRoot <- view projectRootL
    Docker.reexecWithOptionalContainer
        projectRoot
        Nothing
        (Nix.reexecWithOptionalShell projectRoot compilerVersion $ do
         (wantedCompiler, compilerCheck, mstack) <-
           case scoCompilerVersion of
             Just v -> pure (v, MatchMinor, Nothing)
             Nothing -> (,,)
               <$> pure compilerVersion
               <*> view (configL.to configCompilerCheck)
               <*> (Just <$> view stackYamlL)
         setup sco wantedCompiler compilerCheck mstack
         )
        Nothing
        (Just $ munlockFile lk)


-- FIXME! Out of date comment
--
-- A runner specially built for the "stack clean" use case. For some
-- reason (hysterical raisins?), all of the functions in this module
-- which say BuildConfig actually work on an EnvConfig, while the
-- clean command legitimately only needs a BuildConfig. At some point
-- in the future, we could consider renaming everything for more
-- consistency.
--
-- /NOTE/ This command always runs outside of the Docker environment,
-- since it does not need to run any commands to get information on
-- the project. This is a change as of #4480. For previous behavior,
-- see issue #2010.
cleanCmd :: CleanOpts -> RIO Runner ()
cleanCmd opts = withLoadConfig $ withActualBuildConfigAndLock $ \_lock -> clean opts

-- | Helper for build and install commands
buildCmd :: BuildOptsCLI -> RIO Runner ()
buildCmd opts = do
  when (any (("-prof" `elem`) . either (const []) id . parseArgs Escaping) (boptsCLIGhcOptions opts)) $ do
    logError "Error: When building with stack, you should not use the -prof GHC option"
    logError "Instead, please use --library-profiling and --executable-profiling"
    logError "See: https://github.com/commercialhaskell/stack/issues/1015"
    liftIO exitFailure
  withLoadConfig $ withActualBuildConfig $ case boptsCLIFileWatch opts of
    FileWatchPoll -> withRunInIO $ \run -> fileWatchPoll stderr (run . inner . Just)
    FileWatch -> withRunInIO $ \run -> fileWatch stderr (run . inner . Just)
    NoFileWatch -> inner Nothing
  where
    inner setLocalFiles =
      local (over globalOptsL modifyGO) $
      withBuildConfigAndLock NeedTargets opts $ \lk ->
      Stack.Build.build setLocalFiles lk
    -- Read the build command from the CLI and enable it to run
    modifyGO go =
          case boptsCLICommand opts of
               Test -> set (globalOptsBuildOptsMonoidL.buildOptsMonoidTestsL) (Just True) go
               Haddock -> set (globalOptsBuildOptsMonoidL.buildOptsMonoidHaddockL) (Just True) go
               Bench -> set (globalOptsBuildOptsMonoidL.buildOptsMonoidBenchmarksL) (Just True) go
               Install -> set (globalOptsBuildOptsMonoidL.buildOptsMonoidInstallExesL) (Just True) go
               Build -> go -- Default case is just Build

uninstallCmd :: [String] -> RIO Runner ()
uninstallCmd _ =
    prettyErrorL
      [ flow "stack does not manage installations in global locations."
      , flow "The only global mutation stack performs is executable copying."
      , flow "For the default executable destination, please run"
      , PP.style Shell "stack path --local-bin"
      ]

-- | Unpack packages to the filesystem
unpackCmd :: ([String], Maybe Text) -> RIO Runner ()
unpackCmd (names, Nothing) = unpackCmd (names, Just ".")
unpackCmd (names, Just dstPath) =
  withLoadConfigAndLock $ \_lk -> do -- FIXME does this need to deal with Docker?
    go <- view globalOptsL
    mSnapshotDef <- mapM (makeConcreteResolver >=> flip loadResolver Nothing) (globalResolver go)
    dstPath' <- resolveDir' $ T.unpack dstPath
    unpackPackages mSnapshotDef dstPath' names

-- | Update the package index
updateCmd :: () -> RIO Runner ()
updateCmd () =
  withLoadConfigAndLock -- FIXME does this need to deal with Docker?
  (\_lk -> void (updateHackageIndex Nothing))

upgradeCmd :: UpgradeOpts -> RIO Runner ()
upgradeCmd upgradeOpts' = do
  go <- view globalOptsL
  case globalResolver go of
    Just _ -> do
      logError "You cannot use the --resolver option with the upgrade command"
      liftIO exitFailure
    Nothing ->
      withGlobalConfigAndLock $
      upgrade
        (globalConfigMonoid go)
#ifdef USE_GIT_INFO
        (either (const Nothing) (Just . giHash) $$tGitInfoCwdTry)
#else
        Nothing
#endif
        upgradeOpts'

-- | Upload to Hackage
uploadCmd :: SDistOpts -> RIO Runner ()
uploadCmd (SDistOpts [] _ _ _ _ _ _) = do
    prettyErrorL $
        [ flow "To upload the current package, please run"
        , PP.style Shell "stack upload ."
        , flow "(with the period at the end)"
        ]
    liftIO exitFailure
uploadCmd sdistOpts = do
    let partitionM _ [] = return ([], [])
        partitionM f (x:xs) = do
            r <- f x
            (as, bs) <- partitionM f xs
            return $ if r then (x:as, bs) else (as, x:bs)
    (files, nonFiles) <- liftIO $ partitionM D.doesFileExist (sdoptsDirsToWorkWith sdistOpts)
    (dirs, invalid) <- liftIO $ partitionM D.doesDirectoryExist nonFiles
    withLoadConfig $ withActualBuildConfig $ withDefaultBuildConfigAndLock $ \_ -> do
        unless (null invalid) $ do
            let invalidList = bulletedList $ map (PP.style File . fromString) invalid
            prettyErrorL
                [ PP.style Shell "stack upload"
                , flow "expects a list of sdist tarballs or package directories."
                , flow "Can't find:"
                , line <> invalidList
                ]
            liftIO exitFailure
        when (null files && null dirs) $ do
            prettyErrorL
                [ PP.style Shell "stack upload"
                , flow "expects a list of sdist tarballs or package directories, but none were specified."
                ]
            liftIO exitFailure
        config <- view configL
        let hackageUrl = T.unpack $ configHackageBaseUrl config
        getCreds <- liftIO $ memoizeRef $ Upload.loadCreds config
        mapM_ (resolveFile' >=> checkSDistTarball sdistOpts) files
        forM_
            files
            (\file ->
                  do tarFile <- resolveFile' file
                     liftIO $ do
                       creds <- runMemoized getCreds
                       Upload.upload hackageUrl creds (toFilePath tarFile)
                     when
                         (sdoptsSign sdistOpts)
                         (void $
                          Sig.sign
                              (sdoptsSignServerUrl sdistOpts)
                              tarFile))
        unless (null dirs) $
            forM_ dirs $ \dir -> do
                pkgDir <- resolveDir' dir
                (tarName, tarBytes, mcabalRevision) <- getSDistTarball (sdoptsPvpBounds sdistOpts) pkgDir
                checkSDistTarball' sdistOpts tarName tarBytes
                liftIO $ do
                  creds <- runMemoized getCreds
                  Upload.uploadBytes hackageUrl creds tarName tarBytes
                  forM_ mcabalRevision $ uncurry $ Upload.uploadRevision hackageUrl creds
                tarPath <- parseRelFile tarName
                when
                    (sdoptsSign sdistOpts)
                    (void $
                     Sig.signTarBytes
                         (sdoptsSignServerUrl sdistOpts)
                         tarPath
                         tarBytes)

sdistCmd :: SDistOpts -> RIO Runner ()
sdistCmd sdistOpts =
    withLoadConfig $ withActualBuildConfig $ withDefaultBuildConfig $ do -- No locking needed.
        -- If no directories are specified, build all sdist tarballs.
        dirs' <- if null (sdoptsDirsToWorkWith sdistOpts)
            then do
                dirs <- view $ buildConfigL.to (map ppRoot . Map.elems . smwProject . bcSMWanted)
                when (null dirs) $ do
                    stackYaml <- view stackYamlL
                    prettyErrorL
                        [ PP.style Shell "stack sdist"
                        , flow "expects a list of targets, and otherwise defaults to all of the project's packages."
                        , flow "However, the configuration at"
                        , pretty stackYaml
                        , flow "contains no packages, so no sdist tarballs will be generated."
                        ]
                    liftIO exitFailure
                return dirs
            else mapM resolveDir' (sdoptsDirsToWorkWith sdistOpts)
        forM_ dirs' $ \dir -> do
            (tarName, tarBytes, _mcabalRevision) <- getSDistTarball (sdoptsPvpBounds sdistOpts) dir
            distDir <- distDirFromDir dir
            tarPath <- (distDir </>) <$> parseRelFile tarName
            ensureDir (parent tarPath)
            liftIO $ L.writeFile (toFilePath tarPath) tarBytes
            prettyInfoL [flow "Wrote sdist tarball to", pretty tarPath]
            checkSDistTarball sdistOpts tarPath
            forM_ (sdoptsTarPath sdistOpts) $ copyTarToTarPath tarPath tarName
            when (sdoptsSign sdistOpts) (void $ Sig.sign (sdoptsSignServerUrl sdistOpts) tarPath)
        where
          copyTarToTarPath tarPath tarName targetDir = liftIO $ do
            let targetTarPath = targetDir FP.</> tarName
            D.createDirectoryIfMissing True $ FP.takeDirectory targetTarPath
            D.copyFile (toFilePath tarPath) targetTarPath

-- | Execute a command.
execCmd :: ExecOpts -> RIO Runner ()
execCmd ExecOpts {..} =
    case eoExtra of
        ExecOptsPlain -> withLoadConfig $ withActualBuildConfigAndLock $ \lk -> do
          compilerVersion <- view wantedCompilerVersionL
          projectRoot <- view projectRootL
          Docker.reexecWithOptionalContainer
              projectRoot
              -- Unlock before transferring control away, whether using docker or not:
              (Just $ munlockFile lk)
              (withDefaultBuildConfigAndLock $ \buildLock -> do -- FIXME this has to be broken, right? we already did the loading!
                  config <- view configL
                  menv <- liftIO $ configProcessContextSettings config plainEnvSettings
                  withProcessContext menv $ do
                      (cmd, args) <- case (eoCmd, eoArgs) of
                          (ExecCmd cmd, args) -> return (cmd, args)
                          (ExecRun, args) -> getRunCmd args
                          (ExecGhc, args) -> return ("ghc", args)
                          (ExecRunGhc, args) -> return ("runghc", args)
                      munlockFile buildLock
                      Nix.reexecWithOptionalShell projectRoot compilerVersion (exec cmd args))
              Nothing
              Nothing -- Unlocked already above.
        ExecOptsEmbellished {..} -> do
            let targets = concatMap words eoPackages
                boptsCLI = defaultBuildOptsCLI
                           { boptsCLITargets = map T.pack targets
                           }
            withLoadConfig $ withActualBuildConfig $ withBuildConfigAndLock AllowNoTargets boptsCLI $ \lk -> do
              unless (null targets) $ Stack.Build.build Nothing lk

              config <- view configL
              menv <- liftIO $ configProcessContextSettings config eoEnvSettings
              withProcessContext menv $ do
                -- Add RTS options to arguments
                let argsWithRts args = if null eoRtsOptions
                            then args :: [String]
                            else args ++ ["+RTS"] ++ eoRtsOptions ++ ["-RTS"]
                (cmd, args) <- case (eoCmd, argsWithRts eoArgs) of
                    (ExecCmd cmd, args) -> return (cmd, args)
                    (ExecRun, args) -> getRunCmd args
                    (ExecGhc, args) -> getGhcCmd "" eoPackages args
                    -- NOTE: This doesn't work for GHCJS, because it doesn't have
                    -- a runghcjs binary.
                    (ExecRunGhc, args) ->
                        getGhcCmd "run" eoPackages args
                munlockFile lk -- Unlock before transferring control away.

                runWithPath eoCwd $ exec cmd args
  where
      -- return the package-id of the first package in GHC_PACKAGE_PATH
      getPkgId wc name = do
          mId <- findGhcPkgField wc [] name "id"
          case mId of
              Just i -> return (head $ words (T.unpack i))
              -- should never happen as we have already installed the packages
              _      -> liftIO $ do
                  hPutStrLn stderr ("Could not find package id of package " ++ name)
                  exitFailure

      getPkgOpts wc pkgs =
          map ("-package-id=" ++) <$> mapM (getPkgId wc) pkgs

      getRunCmd args = do
          packages <- view $ buildConfigL.to (smwProject . bcSMWanted)
          pkgComponents <- for (Map.elems packages) ppComponents
          let executables = filter isCExe $ concatMap Set.toList pkgComponents
          let (exe, args') = case args of
                             []   -> (firstExe, args)
                             x:xs -> case find (\y -> y == (CExe $ T.pack x)) executables of
                                     Nothing -> (firstExe, args)
                                     argExe -> (argExe, xs)
                             where
                                firstExe = listToMaybe executables
          case exe of
              Just (CExe exe') -> do
                withNewLocalBuildTargets [T.cons ':' exe'] $ Stack.Build.build Nothing Nothing
                return (T.unpack exe', args')
              _                -> do
                  logError "No executables found."
                  liftIO exitFailure

      getGhcCmd prefix pkgs args = do
          wc <- view $ actualCompilerVersionL.whichCompilerL
          pkgopts <- getPkgOpts wc pkgs
          return (prefix ++ compilerExeName wc, pkgopts ++ args)

      runWithPath :: Maybe FilePath -> RIO EnvConfig () -> RIO EnvConfig ()
      runWithPath path callback = case path of
        Nothing                  -> callback
        Just p | not (isValid p) -> throwIO $ InvalidPathForExec p
        Just p                   -> withUnliftIO $ \ul -> D.withCurrentDirectory p $ unliftIO ul callback

-- | Evaluate some haskell code inline.
evalCmd :: EvalOpts -> RIO Runner ()
evalCmd EvalOpts {..} = execCmd execOpts
    where
      execOpts =
          ExecOpts { eoCmd = ExecGhc
                   , eoArgs = ["-e", evalArg]
                   , eoExtra = evalExtra
                   }

-- | Run GHCi in the context of a project.
ghciCmd :: GhciOpts -> RIO Runner ()
ghciCmd ghciOpts =
  let boptsCLI = defaultBuildOptsCLI
          -- using only additional packages, targets then get overriden in `ghci`
          { boptsCLITargets = map T.pack (ghciAdditionalPackages  ghciOpts)
          , boptsCLIInitialBuildSteps = True
          , boptsCLIFlags = ghciFlags ghciOpts
          , boptsCLIGhcOptions = ghciGhcOptions ghciOpts
          }
  in withLoadConfig $
     withActualBuildConfig $
     withBuildConfigAndLock AllowNoTargets boptsCLI $ \lk -> do
    munlockFile lk -- Don't hold the lock while in the GHCI.
    bopts <- view buildOptsL
    -- override env so running of tests and benchmarks is disabled
    let boptsLocal = bopts
               { boptsTestOpts = (boptsTestOpts bopts) { toDisableRun = True }
               , boptsBenchmarkOpts = (boptsBenchmarkOpts bopts) { beoDisableRun = True }
               }
    local (set buildOptsL boptsLocal)
          (ghci ghciOpts)

-- | List packages in the project.
idePackagesCmd :: (IDE.OutputStream, IDE.ListPackagesCmd) -> RIO Runner ()
idePackagesCmd (stream, cmd) =
    withLoadConfig $ withActualBuildConfig $ IDE.listPackages stream cmd

-- | List targets in the project.
ideTargetsCmd :: IDE.OutputStream -> RIO Runner ()
ideTargetsCmd stream =
    withLoadConfig $ withActualBuildConfig $ IDE.listTargets stream

-- | Pull the current Docker image.
dockerPullCmd :: () -> RIO Runner ()
dockerPullCmd () = withLoadConfig $ Docker.preventInContainer Docker.pull

-- | Reset the Docker sandbox.
dockerResetCmd :: Bool -> RIO Runner ()
dockerResetCmd keepHome = do
  withLoadConfig $ do
    mProjectRoot <- view $ to configProjectRoot
    case mProjectRoot of
      Nothing -> error "Cannot call docker reset without a project"
      Just projectRoot ->
        Docker.preventInContainer $ Docker.reset projectRoot keepHome

-- | Cleanup Docker images and containers.
dockerCleanupCmd :: Docker.CleanupOpts -> RIO Runner ()
dockerCleanupCmd cleanupOpts =
  withLoadConfig $
  Docker.preventInContainer $ Docker.cleanup cleanupOpts

cfgSetCmd :: ConfigCmd.ConfigCmdSet -> RIO Runner ()
cfgSetCmd = withGlobalConfigAndLock . cfgCmdSet

imgDockerCmd :: (Bool, [Text]) -> RIO Runner ()
imgDockerCmd (rebuild,images) = withLoadConfig $ withActualBuildConfig $ do
    mProjectRoot <- view $ configL.to configProjectRoot
    withBuildConfigExt
        WithDocker
        NeedTargets
        defaultBuildOptsCLI
        Nothing
        (\lk ->
              do when rebuild $ Stack.Build.build Nothing lk
                 Image.stageContainerImageArtifacts mProjectRoot images)
        (Just $ Image.createContainerImageFromStage mProjectRoot images)

-- | Project initialization
initCmd :: InitOpts -> RIO Runner ()
initCmd initOpts = do
    pwd <- getCurrentDir
    go <- view globalOptsL
    withGlobalConfigAndLock (initProject IsInitCmd pwd initOpts (globalResolver go))

-- | Create a project directory structure and initialize the stack config.
newCmd :: (NewOpts,InitOpts) -> RIO Runner ()
newCmd (newOpts,initOpts) =
    withGlobalConfigAndLock $ do
        dir <- new newOpts (forceOverwrite initOpts)
        exists <- doesFileExist $ dir </> stackDotYaml
        go <- view globalOptsL
        when (forceOverwrite initOpts || not exists) $
            initProject IsNewCmd dir initOpts (globalResolver go)

-- | List the available templates.
templatesCmd :: () -> RIO Runner ()
templatesCmd () = templatesHelp

-- | Fix up extra-deps for a project
solverCmd :: Bool -- ^ modify stack.yaml automatically?
          -> RIO Runner ()
solverCmd fixStackYaml =
  withLoadConfig $
  withActualBuildConfig $
  withDefaultBuildConfigAndLock (\_ -> solveExtraDeps fixStackYaml)

-- | Visualize dependencies
dotCmd :: DotOpts -> RIO Runner ()
dotCmd dotOpts =
  withLoadConfig $
  withActualBuildConfig $
  withBuildConfigDot dotOpts $ dot dotOpts

-- | Query build information
queryCmd :: [String] -> RIO Runner ()
queryCmd selectors =
  withLoadConfig $
  withActualBuildConfig $
  withDefaultBuildConfig $
  queryBuildInfo $ map T.pack selectors

-- | Generate a combined HPC report
hpcReportCmd :: HpcReportOpts -> RIO Runner ()
hpcReportCmd hropts = do
    let (tixFiles, targetNames) = partition (".tix" `T.isSuffixOf`) (hroptsInputs hropts)
        boptsCLI = defaultBuildOptsCLI
          { boptsCLITargets = if hroptsAll hropts then [] else targetNames }
    withLoadConfig $ withActualBuildConfig $
      withBuildConfig AllowNoTargets boptsCLI $
      generateHpcReportForTargets hropts tixFiles targetNames

freezeCmd :: FreezeOpts -> RIO Runner ()
freezeCmd = withLoadConfig . withActualBuildConfig . withDefaultBuildConfig . freeze

data MainException = InvalidReExecVersion String String
                   | UpgradeCabalUnusable
                   | InvalidPathForExec FilePath
     deriving (Typeable)
instance Exception MainException
instance Show MainException where
    show (InvalidReExecVersion expected actual) = concat
        [ "When re-executing '"
        , stackProgName
        , "' in a container, the incorrect version was found\nExpected: "
        , expected
        , "; found: "
        , actual]
    show UpgradeCabalUnusable = "--upgrade-cabal cannot be used when nix is activated"
    show (InvalidPathForExec path) = concat
        [ "Got an invalid --cwd argument for stack exec ("
        , path
        , ")"]
