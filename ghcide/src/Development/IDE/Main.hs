module Development.IDE.Main
(Arguments(..)
,Command(..)
,defaultMain
) where
import           Control.Concurrent.Extra              (newLock, readVar,
                                                        withLock)
import           Control.Concurrent.STM
import           Control.Exception.Safe                (Exception (displayException),
                                                        catchAny)
import           Control.Monad.Extra                   (concatMapM, unless,
                                                        when)
import           Control.Monad.IO.Class
import           Data.Default                          (Default (def))
import           Data.Foldable                         (toList)
import qualified Data.HashMap.Strict                   as HashMap
import           Data.Hashable                         (hashed)
import           Data.List.Extra                       (intercalate, isPrefixOf,
                                                        nub, nubOrd, partition)
import           Data.Maybe                            (catMaybes, fromMaybe,
                                                        isJust, isNothing)
import qualified Data.Text                             as T
import qualified Data.Text.IO                          as T
import           Development.IDE                       (Action,
                                                        GetKnownTargets (GetKnownTargets),
                                                        GetModIfaceFromDiskAndIndex (GetModIfaceFromDiskAndIndex),
                                                        Rules, hDuplicateTo')
import           Development.IDE.Core.Debouncer        (Debouncer,
                                                        newAsyncDebouncer)
import           Development.IDE.Core.FileStore        (makeVFSHandle)
import           Development.IDE.Core.IdeConfiguration (IdeConfiguration (..),
                                                        registerIdeConfiguration)
import           Development.IDE.Core.OfInterest       (FileOfInterestStatus (OnDisk),
                                                        kick,
                                                        setFilesOfInterest)
import           Development.IDE.Core.RuleTypes        (GenerateCore (GenerateCore),
                                                        GetHieAst (GetHieAst),
                                                        GhcSession (GhcSession),
                                                        GhcSessionDeps (GhcSessionDeps),
                                                        TypeCheck (TypeCheck))
import           Development.IDE.Core.Rules            (GhcSessionIO (GhcSessionIO),
                                                        mainRule)
import           Development.IDE.Core.Service          (initialise, runAction)
import           Development.IDE.Core.Shake            (HieDbWriter (indexPending),
                                                        IdeState (shakeExtras),
                                                        ShakeExtras (hiedbWriter, state),
                                                        toKnownFiles,
                                                        useNoFile_, uses)
import           Development.IDE.Core.Tracing          (measureMemory)
import           Development.IDE.LSP.LanguageServer    (runLanguageServer)
import           Development.IDE.Plugin                (Plugin (pluginHandlers, pluginRules))
import           Development.IDE.Plugin.HLS            (asGhcIdePlugin)
import qualified Development.IDE.Plugin.HLS.GhcIde     as Ghcide
import           Development.IDE.Session               (SessionLoadingOptions,
                                                        getHieDbLoc,
                                                        loadSessionWithOptions,
                                                        runWithDb,
                                                        setInitialDynFlags)
import           Development.IDE.Types.Location        (NormalizedUri,
                                                        toNormalizedFilePath')
import           Development.IDE.Types.Logger          (Logger (Logger))
import           Development.IDE.Types.Options         (IdeGhcSession,
                                                        IdeOptions (optCheckParents, optCheckProject, optReportProgress),
                                                        clientSupportsProgress,
                                                        defaultIdeOptions)
import           Development.IDE.Types.Shake           (Key (Key))
import           Development.Shake                     (action)
import           GHC.IO.Encoding                       (setLocaleEncoding)
import           GHC.IO.Handle                         (hDuplicate)
import           HIE.Bios.Cradle                       (findCradle)
import qualified HieDb.Run                             as HieDb
import           Ide.Plugin.Config                     (CheckParents (NeverCheck),
                                                        Config,
                                                        getConfigFromNotification)
import           Ide.PluginUtils                       (allLspCmdIds',
                                                        getProcessID,
                                                        pluginDescToIdePlugins)
import           Ide.Types                             (IdePlugins)
import qualified Language.LSP.Server                   as LSP
import qualified System.Directory.Extra                as IO
import           System.Exit                           (ExitCode (ExitFailure),
                                                        exitWith)
import           System.FilePath                       (takeExtension,
                                                        takeFileName)
import           System.IO                             (BufferMode (LineBuffering, NoBuffering),
                                                        Handle, hFlush,
                                                        hPutStrLn,
                                                        hSetBuffering,
                                                        hSetEncoding, stderr,
                                                        stdin, stdout, utf8)
import           System.Time.Extra                     (offsetTime,
                                                        showDuration)
import           Text.Printf                           (printf)

data Command
    = Lsp   -- ^ Run the LSP server
    | Check [FilePath]  -- ^ Typecheck some paths and print diagnostics. Exit code is the number of failures
    | Index [FilePath]  -- ^ Index all the targets and print the path to the database
    | Db FilePath HieDb.Options HieDb.Command -- ^ Run a command in the hiedb

data Arguments = Arguments
    { argsOTMemoryProfiling     :: Bool
    , argCommand                :: Command
    , argsLogger                :: IO Logger
    , argsRules                 :: Rules ()
    , argsHlsPlugins            :: IdePlugins IdeState
    , argsGhcidePlugin          :: Plugin Config  -- ^ Deprecated
    , argsSessionLoadingOptions :: SessionLoadingOptions
    , argsIdeOptions            :: Config -> Action IdeGhcSession -> IdeOptions
    , argsLspOptions            :: LSP.Options
    , argsDefaultHlsConfig      :: Config
    , argsGetHieDbLoc           :: FilePath -> IO FilePath -- ^ Map project roots to the location of the hiedb for the project
    , argsDebouncer             :: IO (Debouncer NormalizedUri) -- ^ Debouncer used for diagnostics
    , argsHandleIn              :: IO Handle
    , argsHandleOut             :: IO Handle
    }

instance Default Arguments where
    def = Arguments
        { argsOTMemoryProfiling = False
        , argCommand = Lsp
        , argsLogger = stderrLogger
        , argsRules = mainRule >> action kick
        , argsGhcidePlugin = mempty
        , argsHlsPlugins = pluginDescToIdePlugins Ghcide.descriptors
        , argsSessionLoadingOptions = def
        , argsIdeOptions = const defaultIdeOptions
        , argsLspOptions = def {LSP.completionTriggerCharacters = Just "."}
        , argsDefaultHlsConfig = def
        , argsGetHieDbLoc = getHieDbLoc
        , argsDebouncer = newAsyncDebouncer
        , argsHandleIn = pure stdin
        , argsHandleOut = do
                -- Move stdout to another file descriptor and duplicate stderr
                -- to stdout. This guards against stray prints from corrupting the JSON-RPC
                -- message stream.
                newStdout <- hDuplicate stdout
                stderr `hDuplicateTo'` stdout
                hSetBuffering stdout NoBuffering

                -- Print out a single space to assert that the above redirection works.
                -- This is interleaved with the logger, hence we just print a space here in
                -- order not to mess up the output too much. Verified that this breaks
                -- the language server tests without the redirection.
                putStr " " >> hFlush stdout
                return newStdout
        }

-- | Cheap stderr logger that relies on LineBuffering
stderrLogger :: IO Logger
stderrLogger = do
    lock <- newLock
    return $ Logger $ \p m -> withLock lock $
        T.hPutStrLn stderr $ "[" <> T.pack (show p) <> "] " <> m

defaultMain :: Arguments -> IO ()
defaultMain Arguments{..} = do
    setLocaleEncoding utf8
    pid <- T.pack . show <$> getProcessID
    logger <- argsLogger
    hSetBuffering stderr LineBuffering

    let hlsPlugin = asGhcIdePlugin argsHlsPlugins
        hlsCommands = allLspCmdIds' pid argsHlsPlugins
        plugins = hlsPlugin <> argsGhcidePlugin
        options = argsLspOptions { LSP.executeCommandCommands = LSP.executeCommandCommands argsLspOptions <> Just hlsCommands }
        argsOnConfigChange = getConfigFromNotification
        rules = argsRules >> pluginRules plugins

    debouncer <- argsDebouncer
    inH <- argsHandleIn
    outH <- argsHandleOut

    case argCommand of
        Lsp -> do
            t <- offsetTime
            hPutStrLn stderr "Starting LSP server..."
            hPutStrLn stderr "If you are seeing this in a terminal, you probably should have run ghcide WITHOUT the --lsp option!"
            runLanguageServer options inH outH argsGetHieDbLoc argsDefaultHlsConfig argsOnConfigChange (pluginHandlers plugins) $ \env vfs rootPath hiedb hieChan -> do
                t <- t
                hPutStrLn stderr $ "Started LSP server in " ++ showDuration t

                dir <- IO.getCurrentDirectory

                -- We want to set the global DynFlags right now, so that we can use
                -- `unsafeGlobalDynFlags` even before the project is configured
                -- We do it here since haskell-lsp changes our working directory to the correct place ('rootPath')
                -- before calling this function
                _mlibdir <-
                    setInitialDynFlags argsSessionLoadingOptions
                        `catchAny` (\e -> (hPutStrLn stderr $ "setInitialDynFlags: " ++ displayException e) >> pure Nothing)

                sessionLoader <- loadSessionWithOptions argsSessionLoadingOptions $ fromMaybe dir rootPath
                config <- LSP.runLspT env LSP.getConfig
                let options = (argsIdeOptions config sessionLoader)
                            { optReportProgress = clientSupportsProgress caps
                            }
                    caps = LSP.resClientCapabilities env
                initialise
                    argsDefaultHlsConfig
                    rules
                    (Just env)
                    logger
                    debouncer
                    options
                    vfs
                    hiedb
                    hieChan
        Check argFiles -> do
          dir <- IO.getCurrentDirectory
          dbLoc <- getHieDbLoc dir
          runWithDb dbLoc $ \hiedb hieChan -> do
            -- GHC produces messages with UTF8 in them, so make sure the terminal doesn't error
            hSetEncoding stdout utf8
            hSetEncoding stderr utf8

            putStrLn $ "ghcide setup tester in " ++ dir ++ "."
            putStrLn "Report bugs at https://github.com/haskell/haskell-language-server/issues"

            putStrLn $ "\nStep 1/4: Finding files to test in " ++ dir
            files <- expandFiles (argFiles ++ ["." | null argFiles])
            -- LSP works with absolute file paths, so try and behave similarly
            files <- nubOrd <$> mapM IO.canonicalizePath files
            putStrLn $ "Found " ++ show (length files) ++ " files"

            putStrLn "\nStep 2/4: Looking for hie.yaml files that control setup"
            cradles <- mapM findCradle files
            let ucradles = nubOrd cradles
            let n = length ucradles
            putStrLn $ "Found " ++ show n ++ " cradle" ++ ['s' | n /= 1]
            when (n > 0) $ putStrLn $ "  (" ++ intercalate ", " (catMaybes ucradles) ++ ")"
            putStrLn "\nStep 3/4: Initializing the IDE"
            vfs <- makeVFSHandle
            sessionLoader <- loadSessionWithOptions argsSessionLoadingOptions dir
            let options = (argsIdeOptions argsDefaultHlsConfig sessionLoader)
                        { optCheckParents = pure NeverCheck
                        , optCheckProject = pure False
                        }
            ide <- initialise argsDefaultHlsConfig rules Nothing logger debouncer options vfs hiedb hieChan
            registerIdeConfiguration (shakeExtras ide) $ IdeConfiguration mempty (hashed Nothing)

            putStrLn "\nStep 4/4: Type checking the files"
            setFilesOfInterest ide $ HashMap.fromList $ map ((,OnDisk) . toNormalizedFilePath') files
            results <- runAction "User TypeCheck" ide $ uses TypeCheck (map toNormalizedFilePath' files)
            _results <- runAction "GetHie" ide $ uses GetHieAst (map toNormalizedFilePath' files)
            _results <- runAction "GenerateCore" ide $ uses GenerateCore (map toNormalizedFilePath' files)
            let (worked, failed) = partition fst $ zip (map isJust results) files
            when (failed /= []) $
                putStr $ unlines $ "Files that failed:" : map ((++) " * " . snd) failed

            let nfiles xs = let n = length xs in if n == 1 then "1 file" else show n ++ " files"
            putStrLn $ "\nCompleted (" ++ nfiles worked ++ " worked, " ++ nfiles failed ++ " failed)"

            when argsOTMemoryProfiling $ do
                let valuesRef = state $ shakeExtras ide
                values <- readVar valuesRef
                let consoleObserver Nothing = return $ \size -> printf "Total: %.2fMB\n" (fromIntegral @Int @Double size / 1e6)
                    consoleObserver (Just k) = return $ \size -> printf "  - %s: %.2fKB\n" (show k) (fromIntegral @Int @Double size / 1e3)

                printf "# Shake value store contents(%d):\n" (length values)
                let keys =
                        nub $
                            Key GhcSession :
                            Key GhcSessionDeps :
                            [k | (_, k) <- HashMap.keys values, k /= Key GhcSessionIO]
                            ++ [Key GhcSessionIO]
                measureMemory logger [keys] consoleObserver valuesRef

            unless (null failed) (exitWith $ ExitFailure (length failed))
        Index argFiles -> do
          dbLoc <- getHieDbLoc "."
          files <- expandFiles (argFiles ++ ["." | null argFiles])
          runWithDb dbLoc $ \hiedb hieChan -> do
            vfs <- makeVFSHandle
            sessionLoader <- loadSessionWithOptions argsSessionLoadingOptions "."
            let options = (argsIdeOptions argsDefaultHlsConfig sessionLoader)
                        { optCheckParents = pure NeverCheck
                        , optCheckProject = pure False
                        }
            ide <- initialise argsDefaultHlsConfig rules Nothing logger debouncer options vfs hiedb hieChan
            registerIdeConfiguration (shakeExtras ide) $ IdeConfiguration mempty (hashed Nothing)
            let fois = map toNormalizedFilePath' files
            setFilesOfInterest ide $ HashMap.fromList $ map (,OnDisk) fois
            results <- runAction "Index" ide $ do
                _ <- uses GetModIfaceFromDiskAndIndex fois
                allKnownTargets <- toKnownFiles <$> useNoFile_ GetKnownTargets
                liftIO $ hPutStrLn stderr $ "Indexing " <> show(length allKnownTargets) <> " targets"
                uses GetModIfaceFromDiskAndIndex $ toList allKnownTargets

            hPutStrLn stderr "Writing index... "

            let !nfailures = length $ filter isNothing results
            let !pending = indexPending $ hiedbWriter $ shakeExtras ide

            atomically $ do
                n <- readTVar pending
                unless (HashMap.size n == 0) retry

            putStrLn dbLoc
            unless (nfailures == 0) $ exitWith $ ExitFailure nfailures

        Db dir opts cmd -> do
            dbLoc <- getHieDbLoc dir
            hPutStrLn stderr $ "Using hiedb at: " ++ dbLoc
            mlibdir <- setInitialDynFlags def
            case mlibdir of
                Nothing     -> exitWith $ ExitFailure 1
                Just libdir -> HieDb.runCommand libdir opts{HieDb.database = dbLoc} cmd

{-# ANN defaultMain ("HLint: ignore Use nubOrd" :: String) #-}


expandFiles :: [FilePath] -> IO [FilePath]
expandFiles = concatMapM $ \x -> do
    b <- IO.doesFileExist x
    if b
        then return [x]
        else do
            let recurse "." = True
                recurse x | "." `isPrefixOf` takeFileName x = False -- skip .git etc
                recurse x = takeFileName x `notElem` ["dist", "dist-newstyle"] -- cabal directories
            files <- filter (\x -> takeExtension x `elem` [".hs", ".lhs"]) <$> IO.listFilesInside (return . recurse) x
            when (null files) $
                fail $ "Couldn't find any .hs/.lhs files inside directory: " ++ x
            return files
