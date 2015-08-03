{-# LANGUAGE CPP #-}
module Main where

import Distribution.Package

import Hackage.Security.Client
import Hackage.Security.Util.IO
import Hackage.Security.Util.Path
import Hackage.Security.Util.Pretty
import Hackage.Security.Client.Repository.HttpLib
import qualified Hackage.Security.Client.Repository.Cache       as Cache
import qualified Hackage.Security.Client.Repository.Local       as Local
import qualified Hackage.Security.Client.Repository.Remote      as Remote
import qualified Hackage.Security.Client.Repository.HttpLib.HTTP as HttpLib.HTTP
import qualified Hackage.Security.Client.Repository.HttpLib.Curl as HttpLib.Curl

#if MIN_VERSION_base(4,5,0)
import qualified Hackage.Security.Client.Repository.HttpLib.HttpClient as HttpLib.HttpClient
#endif

import ExampleClient.Options

main :: IO ()
main = do
    opts@GlobalOpts{..} <- getOptions
    case globalCommand of
      Bootstrap threshold -> cmdBootstrap opts threshold
      Check               -> cmdCheck     opts
      Get       pkgId     -> cmdGet       opts pkgId

{-------------------------------------------------------------------------------
  The commands are just thin wrappers around the hackage-security Client API
-------------------------------------------------------------------------------}

cmdBootstrap :: GlobalOpts -> KeyThreshold -> IO ()
cmdBootstrap opts threshold =
    withRepo opts $ \rep -> uncheckClientErrors $ do
      bootstrap rep (globalRootKeys opts) threshold
      putStrLn "OK"

cmdCheck :: GlobalOpts -> IO ()
cmdCheck opts =
    withRepo opts $ \rep -> uncheckClientErrors $
      print =<< checkForUpdates rep (globalCheckExpiry opts)

cmdGet :: GlobalOpts -> PackageIdentifier -> IO ()
cmdGet opts pkgId = do
    cwd <- getCurrentDirectory
    let localFile = cwd </> fragment tarGzName
    withRepo opts $ \rep -> uncheckClientErrors $
      downloadPackage rep pkgId $ \tempPath ->
        atomicCopyFile tempPath localFile
  where
    tarGzName :: Fragment
    tarGzName = takeFileName $ repoLayoutPkgTarGz hackageRepoLayout pkgId

{-------------------------------------------------------------------------------
  Common functionality
-------------------------------------------------------------------------------}

withRepo :: GlobalOpts -> (Repository -> IO a) -> IO a
withRepo GlobalOpts{..} =
    case globalRepo of
      Left  local  -> withLocalRepo  local
      Right remote -> withRemoteRepo remote
  where
    withLocalRepo :: AbsolutePath -> (Repository -> IO a) -> IO a
    withLocalRepo repo =
        Local.withRepository repo
                             cache
                             hackageRepoLayout
                             logTUF

    withRemoteRepo :: URI -> (Repository -> IO a) -> IO a
    withRemoteRepo baseURI callback = withClient $ \httpClient ->
        Remote.withRepository httpClient
                              [baseURI]
                              allowCompression
                              cache
                              hackageRepoLayout
                              logTUF
                              callback

    allowCompression :: Remote.AllowContentCompression
    allowCompression = if globalDisallowCompression
                         then Remote.DisallowContentCompression
                         else Remote.AllowContentCompression

    withClient :: (HttpLib -> IO a) -> IO a
    withClient act =
        case globalHttpClient of
          "HTTP" ->
            HttpLib.HTTP.withClient $ \browser httpLib -> do
              HttpLib.HTTP.setProxy      browser proxyConfig
              HttpLib.HTTP.setOutHandler browser logHTTP
              HttpLib.HTTP.setErrHandler browser logHTTP
              act httpLib
          "curl" ->
            HttpLib.Curl.withClient $ \httpLib ->
              act httpLib
#if MIN_VERSION_base(4,5,0)
          "http-client" ->
            HttpLib.HttpClient.withClient proxyConfig $ \_manager httpLib ->
              act httpLib
#endif
          otherClient ->
            error $ "unsupported HTTP client " ++ show otherClient

    -- use automatic proxy configuration
    proxyConfig :: forall a. ProxyConfig a
    proxyConfig = ProxyConfigAuto

    -- used for log messages from the Hackage.Security code
    logTUF :: LogMessage -> IO ()
    logTUF msg = putStrLn $ "# " ++ pretty msg

    -- used for log messages from the HTTP clients
    logHTTP :: String -> IO ()
    logHTTP = putStrLn

    cache :: Cache.Cache
    cache = Cache.Cache {
        cacheRoot   = globalCache
      , cacheLayout = cabalCacheLayout
      }
