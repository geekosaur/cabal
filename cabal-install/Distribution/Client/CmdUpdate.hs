{-# LANGUAGE CPP             #-}
{-# LANGUAGE LambdaCase      #-}
{-# LANGUAGE NamedFieldPuns  #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TupleSections   #-}
{-# LANGUAGE ViewPatterns    #-}

-- | cabal-install CLI command: update
--
module Distribution.Client.CmdUpdate (
    updateCommand,
    updateAction,
  ) where

import Prelude ()
import Distribution.Client.Compat.Prelude

import Distribution.Client.NixStyleOptions
         ( NixStyleFlags (..), nixStyleOptions, defaultNixStyleFlags )
import Distribution.Client.Compat.Directory
         ( setModificationTime )
import Distribution.Client.ProjectOrchestration
import Distribution.Client.ProjectConfig
         ( ProjectConfig(..)
         , ProjectConfigShared(projectConfigConfigFile)
         , projectConfigWithSolverRepoContext
         , withProjectOrGlobalConfigIgn )
import Distribution.Client.ProjectFlags
         ( ProjectFlags (..), defaultProjectFlags, projectFlagsOptions )
import Distribution.Client.Types
         ( Repo(..), RepoName (..), unRepoName, RemoteRepo(..), isRepoRemote )
import Distribution.Client.HttpUtils
         ( DownloadResult(..) )
import Distribution.Client.FetchUtils
         ( downloadIndex )
import Distribution.Client.JobControl
         ( newParallelJobControl, spawnJob, collectJob )
import Distribution.Client.Setup
         ( GlobalFlags, ConfigFlags(..)
         , UpdateFlags, defaultUpdateFlags
         , RepoContext(..) )
import Distribution.Simple.Flag
         ( fromFlagOrDefault )
import Distribution.Simple.Utils
         ( die', notice, wrapText, writeFileAtomic, noticeNoWrap )
import Distribution.Verbosity
         ( Verbosity, normal, lessVerbose )
import Distribution.Client.IndexUtils.Timestamp
import Distribution.Client.IndexUtils.IndexState
import Distribution.Client.IndexUtils
         ( updateRepoIndexCache, Index(..), writeIndexTimestamp
         , currentIndexTimestamp, indexBaseName )
import Distribution.Pretty (Pretty (..), prettyShow)
import Distribution.Parsec (Parsec (..), simpleParsec)

import Data.Maybe (fromJust)
import qualified Distribution.Compat.CharParsing as P
import qualified Text.PrettyPrint                as Disp

import Control.Monad (mapM, mapM_)
import qualified Data.ByteString.Lazy       as BS
import Distribution.Client.GZipUtils (maybeDecompress)
import System.FilePath ((<.>), dropExtension)
import Data.Time (getCurrentTime)
import Distribution.Simple.Command
         ( CommandUI(..), usageAlternatives, optionName )

import qualified Hackage.Security.Client as Sec

updateCommand :: CommandUI (NixStyleFlags ProjectFlags)
updateCommand = CommandUI
  { commandName         = "v2-update"
  , commandSynopsis     = "Updates list of known packages."
  , commandUsage        = usageAlternatives "v2-update" [ "[FLAGS] [REPOS]" ]
  , commandDescription  = Just $ \_ -> wrapText $
          "For all known remote repositories, download the package list."
  , commandNotes        = Just $ \pname ->
        "REPO has the format <repo-id>[,<index-state>] where index-state follows\n"
     ++ "the same format and syntax that is supported by the --index-state flag.\n\n"
     ++ "Examples:\n"
     ++ "  " ++ pname ++ " v2-update\n"
     ++ "    Download the package list for all known remote repositories.\n\n"
     ++ "  " ++ pname ++ " v2-update hackage.haskell.org,@1474732068\n"
     ++ "  " ++ pname ++ " v2-update hackage.haskell.org,2016-09-24T17:47:48Z\n"
     ++ "  " ++ pname ++ " v2-update hackage.haskell.org,HEAD\n"
     ++ "  " ++ pname ++ " v2-update hackage.haskell.org\n"
     ++ "    Download hackage.haskell.org at a specific index state.\n\n"
     ++ "  " ++ pname ++ " new update hackage.haskell.org head.hackage\n"
     ++ "    Download hackage.haskell.org and head.hackage\n"
     ++ "    head.hackage must be a known repo-id. E.g. from\n"
     ++ "    your cabal.project(.local) file.\n\n"
     ++ "Note: this command is part of the new project-based system (aka "
     ++ "nix-style\nlocal builds). These features are currently in beta. "
     ++ "Please see\n"
     ++ "http://cabal.readthedocs.io/en/latest/nix-local-build-overview.html "
     ++ "for\ndetails and advice on what you can expect to work. If you "
     ++ "encounter problems\nplease file issues at "
     ++ "https://github.com/haskell/cabal/issues and if you\nhave any time "
     ++ "to get involved and help with testing, fixing bugs etc then\nthat "
     ++ "is very much appreciated.\n"
  -- TODO: Add ProjectFlags to NixStyleFlags,
  -- so project-file won't be ambiguous
  , commandOptions      = nixStyleOptions $ const
                        $ filter (\o -> optionName o `notElem` ["project-file"])
                        $ projectFlagsOptions
  , commandDefaultFlags = defaultNixStyleFlags defaultProjectFlags
  }

data UpdateRequest = UpdateRequest
  { _updateRequestRepoName  :: RepoName
  , _updateRequestRepoState :: RepoIndexState
  } deriving (Show)

instance Pretty UpdateRequest where
    pretty (UpdateRequest n s) = pretty n <<>> Disp.comma <<>> pretty s

instance Parsec UpdateRequest where
  parsec = do
      name <- parsec
      state <- P.char ',' *> parsec <|> pure IndexStateHead
      return (UpdateRequest name state)

updateAction :: NixStyleFlags ProjectFlags -> [String] -> GlobalFlags -> IO ()
updateAction NixStyleFlags { extraFlags = projectFlags, ..} extraArgs globalFlags = do
  let ignoreProject = fromFlagOrDefault False (flagIgnoreProject projectFlags)

  projectConfig <- withProjectOrGlobalConfigIgn ignoreProject verbosity globalConfigFlag
    (projectConfig <$> establishProjectBaseContext verbosity cliConfig OtherCommand)
    (\globalConfig -> return $ globalConfig <> cliConfig)

  projectConfigWithSolverRepoContext verbosity
    (projectConfigShared projectConfig) (projectConfigBuildOnly projectConfig)
    $ \repoCtxt -> do
    let repos       = filter isRepoRemote $ repoContextRepos repoCtxt
        repoName    = remoteRepoName . repoRemote
        parseArg :: String -> IO UpdateRequest
        parseArg s = case simpleParsec s of
          Just r -> return r
          Nothing -> die' verbosity $
                     "'v2-update' unable to parse repo: \"" ++ s ++ "\""
    updateRepoRequests <- mapM parseArg extraArgs

    unless (null updateRepoRequests) $ do
      let remoteRepoNames = map repoName repos
          unknownRepos = [r | (UpdateRequest r _) <- updateRepoRequests
                            , not (r `elem` remoteRepoNames)]
      unless (null unknownRepos) $
        die' verbosity $ "'v2-update' repo(s): \""
                         ++ intercalate "\", \"" (map unRepoName unknownRepos)
                         ++ "\" can not be found in known remote repo(s): "
                         ++ intercalate ", " (map unRepoName remoteRepoNames)

    let reposToUpdate :: [(Repo, RepoIndexState)]
        reposToUpdate = case updateRepoRequests of
          -- If we are not given any specific repository, update all
          -- repositories to HEAD.
          [] -> map (,IndexStateHead) repos
          updateRequests -> let repoMap = [(repoName r, r) | r <- repos]
                                lookup' k = fromJust (lookup k repoMap)
                            in [ (lookup' name, state)
                               | (UpdateRequest name state) <- updateRequests ]

    case reposToUpdate of
      [] -> return ()
      [(remoteRepo, _)] ->
        notice verbosity $ "Downloading the latest package list from "
                        ++ unRepoName (repoName remoteRepo)
      _ -> notice verbosity . unlines
              $ "Downloading the latest package lists from: "
              : map (("- " ++) . unRepoName . repoName . fst) reposToUpdate

    jobCtrl <- newParallelJobControl (length reposToUpdate)
    mapM_ (spawnJob jobCtrl . updateRepo verbosity defaultUpdateFlags repoCtxt)
      reposToUpdate
    mapM_ (\_ -> collectJob jobCtrl) reposToUpdate

  where
    verbosity = fromFlagOrDefault normal (configVerbosity configFlags)
    cliConfig = commandLineFlagsToProjectConfig
                  globalFlags configFlags configExFlags
                  installFlags
                  mempty -- ClientInstallFlags, not needed here
                  haddockFlags testFlags benchmarkFlags
    globalConfigFlag = projectConfigConfigFile (projectConfigShared cliConfig)

updateRepo :: Verbosity -> UpdateFlags -> RepoContext -> (Repo, RepoIndexState)
           -> IO ()
updateRepo verbosity _updateFlags repoCtxt (repo, indexState) = do
  transport <- repoContextGetTransport repoCtxt
  case repo of
    RepoLocalNoIndex{} -> return ()
    RepoRemote{..} -> do
      downloadResult <- downloadIndex transport verbosity
                        repoRemote repoLocalDir
      case downloadResult of
        FileAlreadyInCache ->
          setModificationTime (indexBaseName repo <.> "tar")
          =<< getCurrentTime
        FileDownloaded indexPath -> do
          writeFileAtomic (dropExtension indexPath) . maybeDecompress
                                                  =<< BS.readFile indexPath
          updateRepoIndexCache verbosity (RepoIndex repoCtxt repo)
    RepoSecure{} -> repoContextWithSecureRepo repoCtxt repo $ \repoSecure -> do
      let index = RepoIndex repoCtxt repo
      -- NB: This may be a nullTimestamp if we've never updated before
      current_ts <- currentIndexTimestamp (lessVerbose verbosity) repoCtxt repo
      -- NB: always update the timestamp, even if we didn't actually
      -- download anything
      writeIndexTimestamp index indexState
      ce <- if repoContextIgnoreExpiry repoCtxt
              then Just `fmap` getCurrentTime
              else return Nothing
      updated <- Sec.uncheckClientErrors $ Sec.checkForUpdates repoSecure ce

      let rname = remoteRepoName (repoRemote repo)

      -- Update cabal's internal index as well so that it's not out of sync
      -- (If all access to the cache goes through hackage-security this can go)
      case updated of
        Sec.NoUpdates  -> do
          now <- getCurrentTime
          setModificationTime (indexBaseName repo <.> "tar") now
          noticeNoWrap verbosity $
            "Package list of " ++ prettyShow rname ++
            " is up to date at index-state " ++ prettyShow (IndexStateTime current_ts)

        Sec.HasUpdates -> do
          updateRepoIndexCache verbosity index
          new_ts <- currentIndexTimestamp (lessVerbose verbosity) repoCtxt repo
          noticeNoWrap verbosity $
            "Updated package list of " ++ prettyShow rname ++
            " to the index-state " ++ prettyShow (IndexStateTime new_ts)

          -- TODO: This will print multiple times if there are multiple
          -- repositories: main problem is we don't have a way of updating
          -- a specific repo.  Once we implement that, update this.
          when (current_ts /= nullTimestamp) $
            noticeNoWrap verbosity $
              "To revert to previous state run:\n" ++
              "    cabal v2-update '" ++ prettyShow (UpdateRequest rname (IndexStateTime current_ts)) ++ "'\n"
