{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

-----------------------------------------------------------------------------

-- |
-- Module      :  Distribution.Simple.InstallDirs
-- Copyright   :  Isaac Jones 2003-2004
-- License     :  BSD3
--
-- Maintainer  :  cabal-devel@haskell.org
-- Portability :  portable
--
-- This manages everything to do with where files get installed (though does
-- not get involved with actually doing any installation). It provides an
-- 'InstallDirs' type which is a set of directories for where to install
-- things. It also handles the fact that we use templates in these install
-- dirs. For example most install dirs are relative to some @$prefix@ and by
-- changing the prefix all other dirs still end up changed appropriately. So it
-- provides a 'PathTemplate' type and functions for substituting for these
-- templates.
module Distribution.Simple.InstallDirs
  ( InstallDirs (..)
  , InstallDirTemplates
  , defaultInstallDirs
  , defaultInstallDirs'
  , combineInstallDirs
  , absoluteInstallDirs
  , CopyDest (..)
  , prefixRelativeInstallDirs
  , substituteInstallDirTemplates
  , PathTemplate
  , PathTemplateVariable (..)
  , PathTemplateEnv
  , toPathTemplate
  , fromPathTemplate
  , combinePathTemplate
  , substPathTemplate
  , initialPathTemplateEnv
  , platformTemplateEnv
  , compilerTemplateEnv
  , packageTemplateEnv
  , abiTemplateEnv
  , installDirsGrammar
  , installDirsTemplateEnv
  ) where

import Distribution.Compat.Prelude
import Prelude ()

import Distribution.Compat.Environment (lookupEnv)
import Distribution.Compat.Lens (Lens')
import Distribution.Compiler
import Distribution.FieldGrammar
import Distribution.Package
import Distribution.Parsec
import Distribution.Pretty
import Distribution.Simple.Flag
import Distribution.Simple.InstallDirs.Internal
import Distribution.System

import System.Directory (getAppUserDataDirectory)
import System.FilePath
  ( dropDrive
  , isPathSeparator
  , pathSeparator
  , takeDirectory
  , (</>)
  )

#ifdef mingw32_HOST_OS
import qualified Prelude
import Foreign
import Foreign.C
#endif

-- ---------------------------------------------------------------------------
-- Installation directories

-- | The directories where we will install files for packages.
--
-- We have several different directories for different types of files since
-- many systems have conventions whereby different types of files in a package
-- are installed in different directories. This is particularly the case on
-- Unix style systems.
data InstallDirs dir = InstallDirs
  { prefix :: dir
  , bindir :: dir
  , libdir :: dir
  , libsubdir :: dir
  , dynlibdir :: dir
  , flibdir :: dir
  -- ^ foreign libraries
  , libexecdir :: dir
  , libexecsubdir :: dir
  , includedir :: dir
  , datadir :: dir
  , datasubdir :: dir
  , docdir :: dir
  , mandir :: dir
  , htmldir :: dir
  , haddockdir :: dir
  , sysconfdir :: dir
  }
  deriving (Eq, Read, Show, Functor, Generic)

instance Binary dir => Binary (InstallDirs dir)
instance Structured dir => Structured (InstallDirs dir)

instance (Semigroup dir, Monoid dir) => Monoid (InstallDirs dir) where
  mempty = gmempty
  mappend = (<>)

instance Semigroup dir => Semigroup (InstallDirs dir) where
  (<>) = gmappend

combineInstallDirs
  :: (a -> b -> c)
  -> InstallDirs a
  -> InstallDirs b
  -> InstallDirs c
combineInstallDirs combine a b =
  InstallDirs
    { prefix = prefix a `combine` prefix b
    , bindir = bindir a `combine` bindir b
    , libdir = libdir a `combine` libdir b
    , libsubdir = libsubdir a `combine` libsubdir b
    , dynlibdir = dynlibdir a `combine` dynlibdir b
    , flibdir = flibdir a `combine` flibdir b
    , libexecdir = libexecdir a `combine` libexecdir b
    , libexecsubdir = libexecsubdir a `combine` libexecsubdir b
    , includedir = includedir a `combine` includedir b
    , datadir = datadir a `combine` datadir b
    , datasubdir = datasubdir a `combine` datasubdir b
    , docdir = docdir a `combine` docdir b
    , mandir = mandir a `combine` mandir b
    , htmldir = htmldir a `combine` htmldir b
    , haddockdir = haddockdir a `combine` haddockdir b
    , sysconfdir = sysconfdir a `combine` sysconfdir b
    }

appendSubdirs :: (a -> a -> a) -> InstallDirs a -> InstallDirs a
appendSubdirs append dirs =
  dirs
    { libdir = libdir dirs `append` libsubdir dirs
    , libexecdir = libexecdir dirs `append` libexecsubdir dirs
    , datadir = datadir dirs `append` datasubdir dirs
    , libsubdir = error "internal error InstallDirs.libsubdir"
    , libexecsubdir = error "internal error InstallDirs.libexecsubdir"
    , datasubdir = error "internal error InstallDirs.datasubdir"
    }

-- | The installation directories in terms of 'PathTemplate's that contain
-- variables.
--
-- The defaults for most of the directories are relative to each other, in
-- particular they are all relative to a single prefix. This makes it
-- convenient for the user to override the default installation directory
-- by only having to specify --prefix=... rather than overriding each
-- individually. This is done by allowing $-style variables in the dirs.
-- These are expanded by textual substitution (see 'substPathTemplate').
--
-- A few of these installation directories are split into two components, the
-- dir and subdir. The full installation path is formed by combining the two
-- together with @\/@. The reason for this is compatibility with other Unix
-- build systems which also support @--libdir@ and @--datadir@. We would like
-- users to be able to configure @--libdir=\/usr\/lib64@ for example but
-- because by default we want to support installing multiple versions of
-- packages and building the same package for multiple compilers we append the
-- libsubdir to get: @\/usr\/lib64\/$libname\/$compiler@.
--
-- An additional complication is the need to support relocatable packages on
-- systems which support such things, like Windows.
type InstallDirTemplates = InstallDirs PathTemplate

-- ---------------------------------------------------------------------------
-- Default installation directories

defaultInstallDirs :: CompilerFlavor -> Bool -> Bool -> IO InstallDirTemplates
defaultInstallDirs = defaultInstallDirs' False

defaultInstallDirs'
  :: Bool {- use external internal deps -}
  -> CompilerFlavor
  -> Bool
  -> Bool
  -> IO InstallDirTemplates
defaultInstallDirs' True comp userInstall hasLibs = do
  dflt <- defaultInstallDirs' False comp userInstall hasLibs
  -- Be a bit more hermetic about per-component installs
  return
    dflt
      { datasubdir = toPathTemplate $ "$abi" </> "$libname"
      , docdir = toPathTemplate $ "$datadir" </> "doc" </> "$abi" </> "$libname"
      }
defaultInstallDirs' False comp userInstall _hasLibs = do
  installPrefix <-
    if userInstall
      then do
        mDir <- lookupEnv "CABAL_DIR"
        case mDir of
          Nothing -> getAppUserDataDirectory "cabal"
          Just dir -> return dir
      else case buildOS of
        Windows -> do
          windowsProgramFilesDir <- getWindowsProgramFilesDir
          return (windowsProgramFilesDir </> "Haskell")
        Haiku -> return "/boot/system/non-packaged"
        _ -> return "/usr/local"
  installLibDir <-
    case buildOS of
      Windows -> return "$prefix"
      _ -> return ("$prefix" </> "lib")
  return $
    fmap toPathTemplate $
      InstallDirs
        { prefix = installPrefix
        , bindir = "$prefix" </> "bin"
        , libdir = installLibDir
        , libsubdir = case comp of
            UHC -> "$pkgid"
            _other -> "$abi" </> "$libname"
        , dynlibdir =
            "$libdir" </> case comp of
              UHC -> "$pkgid"
              _other -> "$abi"
        , libexecsubdir = "$abi" </> "$pkgid"
        , flibdir = "$libdir"
        , libexecdir = case buildOS of
            Windows -> "$prefix" </> "$libname"
            Haiku -> "$libdir"
            _other -> "$prefix" </> "libexec"
        , includedir = case buildOS of
            Haiku -> "$prefix" </> "develop" </> "headers"
            _other -> "$libdir" </> "$libsubdir" </> "include"
        , datadir = case buildOS of
            Windows -> "$prefix"
            Haiku -> "$prefix" </> "data"
            _other -> "$prefix" </> "share"
        , datasubdir = "$abi" </> "$pkgid"
        , docdir = case buildOS of
            Haiku -> "$prefix" </> "documentation"
            _other -> "$datadir" </> "doc" </> "$abi" </> "$pkgid"
        , mandir = case buildOS of
            Haiku -> "$docdir" </> "man"
            _other -> "$datadir" </> "man"
        , htmldir = "$docdir" </> "html"
        , haddockdir = "$htmldir"
        , sysconfdir = case buildOS of
            Haiku -> "boot" </> "system" </> "settings"
            _other -> "$prefix" </> "etc"
        }

-- ---------------------------------------------------------------------------
-- Converting directories, absolute or prefix-relative

-- | Substitute the install dir templates into each other.
--
-- To prevent cyclic substitutions, only some variables are allowed in
-- particular dir templates. If out of scope vars are present, they are not
-- substituted for. Checking for any remaining unsubstituted vars can be done
-- as a subsequent operation.
--
-- The reason it is done this way is so that in 'prefixRelativeInstallDirs' we
-- can replace 'prefix' with the 'PrefixVar' and get resulting
-- 'PathTemplate's that still have the 'PrefixVar' in them. Doing this makes it
-- each to check which paths are relative to the $prefix.
substituteInstallDirTemplates
  :: PathTemplateEnv
  -> InstallDirTemplates
  -> InstallDirTemplates
substituteInstallDirTemplates env dirs = dirs'
  where
    dirs' =
      InstallDirs
        { -- So this specifies exactly which vars are allowed in each template
          prefix = subst prefix []
        , bindir = subst bindir [prefixVar]
        , libdir = subst libdir [prefixVar, bindirVar]
        , libsubdir = subst libsubdir []
        , dynlibdir = subst dynlibdir [prefixVar, bindirVar, libdirVar]
        , flibdir = subst flibdir [prefixVar, bindirVar, libdirVar]
        , libexecdir = subst libexecdir prefixBinLibVars
        , libexecsubdir = subst libexecsubdir []
        , includedir = subst includedir prefixBinLibVars
        , datadir = subst datadir prefixBinLibVars
        , datasubdir = subst datasubdir []
        , docdir = subst docdir prefixBinLibDataVars
        , mandir = subst mandir (prefixBinLibDataVars ++ [docdirVar])
        , htmldir = subst htmldir (prefixBinLibDataVars ++ [docdirVar])
        , haddockdir =
            subst
              haddockdir
              ( prefixBinLibDataVars
                  ++ [docdirVar, htmldirVar]
              )
        , sysconfdir = subst sysconfdir prefixBinLibVars
        }
    subst dir env' = substPathTemplate (env' ++ env) (dir dirs)

    prefixVar = (PrefixVar, prefix dirs')
    bindirVar = (BindirVar, bindir dirs')
    libdirVar = (LibdirVar, libdir dirs')
    libsubdirVar = (LibsubdirVar, libsubdir dirs')
    datadirVar = (DatadirVar, datadir dirs')
    datasubdirVar = (DatasubdirVar, datasubdir dirs')
    docdirVar = (DocdirVar, docdir dirs')
    htmldirVar = (HtmldirVar, htmldir dirs')
    prefixBinLibVars = [prefixVar, bindirVar, libdirVar, libsubdirVar]
    prefixBinLibDataVars = prefixBinLibVars ++ [datadirVar, datasubdirVar]

-- | Convert from abstract install directories to actual absolute ones by
-- substituting for all the variables in the abstract paths, to get real
-- absolute path.
absoluteInstallDirs
  :: PackageIdentifier
  -> UnitId
  -> CompilerInfo
  -> CopyDest
  -> Platform
  -> InstallDirs PathTemplate
  -> InstallDirs FilePath
absoluteInstallDirs pkgId libname compilerId copydest platform dirs =
  ( case copydest of
      CopyTo destdir -> fmap ((destdir </>) . dropDrive)
      CopyToDb dbdir -> fmap (substPrefix "${pkgroot}" (takeDirectory dbdir))
      _ -> id
  )
    . appendSubdirs (</>)
    . fmap fromPathTemplate
    $ substituteInstallDirTemplates env dirs
  where
    env = initialPathTemplateEnv pkgId libname compilerId platform
    substPrefix pre root path
      | pre `isPrefixOf` path = root ++ drop (length pre) path
      | otherwise = path

-- | The location prefix for the /copy/ command.
data CopyDest
  = NoCopyDest
  | CopyTo FilePath
  | -- | when using the ${pkgroot} as prefix. The CopyToDb will
    --   adjust the paths to be relative to the provided package
    --   database when copying / installing.
    CopyToDb FilePath
  deriving (Eq, Show, Generic)

-- TODO: are these paths absolute or relative? Relative to what?

instance Binary CopyDest
instance Structured CopyDest

-- | Check which of the paths are relative to the installation $prefix.
--
-- If any of the paths are not relative, ie they are absolute paths, then it
-- prevents us from making a relocatable package (also known as a \"prefix
-- independent\" package).
prefixRelativeInstallDirs
  :: PackageIdentifier
  -> UnitId
  -> CompilerInfo
  -> Platform
  -> InstallDirTemplates
  -> InstallDirs (Maybe FilePath)
prefixRelativeInstallDirs pkgId libname compilerId platform dirs =
  fmap relative
    . appendSubdirs combinePathTemplate
    $ substituteInstallDirTemplates -- substitute the path template into each other, except that we map
    -- \$prefix back to $prefix. We're trying to end up with templates that
    -- mention no vars except $prefix.
      env
      dirs
        { prefix = PathTemplate [Variable PrefixVar]
        }
  where
    env = initialPathTemplateEnv pkgId libname compilerId platform

    -- If it starts with $prefix then it's relative and produce the relative
    -- path by stripping off $prefix/ or $prefix
    relative dir = case dir of
      PathTemplate cs -> fmap (fromPathTemplate . PathTemplate) (relative' cs)
    relative' (Variable PrefixVar : Ordinary (s : rest) : rest')
      | isPathSeparator s = Just (Ordinary rest : rest')
    relative' (Variable PrefixVar : rest) = Just rest
    relative' _ = Nothing

-- ---------------------------------------------------------------------------
-- Path templates

-- | An abstract path, possibly containing variables that need to be
-- substituted for to get a real 'FilePath'.
newtype PathTemplate = PathTemplate [PathComponent]
  deriving (Eq, Ord, Generic)

instance Binary PathTemplate
instance Structured PathTemplate

type PathTemplateEnv = [(PathTemplateVariable, PathTemplate)]

-- | Convert a 'FilePath' to a 'PathTemplate' including any template vars.
toPathTemplate :: FilePath -> PathTemplate
toPathTemplate fp =
  PathTemplate
    . fromMaybe (error $ "panic! toPathTemplate " ++ show fp)
    . readMaybe -- TODO: eradicateNoParse
    $ fp

-- | Convert back to a path, any remaining vars are included
fromPathTemplate :: PathTemplate -> FilePath
fromPathTemplate (PathTemplate template) = show template

combinePathTemplate :: PathTemplate -> PathTemplate -> PathTemplate
combinePathTemplate (PathTemplate t1) (PathTemplate t2) =
  PathTemplate (t1 ++ [Ordinary [pathSeparator]] ++ t2)

substPathTemplate :: PathTemplateEnv -> PathTemplate -> PathTemplate
substPathTemplate environment (PathTemplate template) =
  PathTemplate (concatMap subst template)
  where
    subst component@(Ordinary _) = [component]
    subst component@(Variable variable) =
      case lookup variable environment of
        Just (PathTemplate components) -> components
        Nothing -> [component]

-- | The initial environment has all the static stuff but no paths
initialPathTemplateEnv
  :: PackageIdentifier
  -> UnitId
  -> CompilerInfo
  -> Platform
  -> PathTemplateEnv
initialPathTemplateEnv pkgId libname compiler platform =
  packageTemplateEnv pkgId libname
    ++ compilerTemplateEnv compiler
    ++ platformTemplateEnv platform
    ++ abiTemplateEnv compiler platform

packageTemplateEnv :: PackageIdentifier -> UnitId -> PathTemplateEnv
packageTemplateEnv pkgId uid =
  [ (PkgNameVar, PathTemplate [Ordinary $ prettyShow (packageName pkgId)])
  , (PkgVerVar, PathTemplate [Ordinary $ prettyShow (packageVersion pkgId)])
  , -- Invariant: uid is actually a HashedUnitId.  Hard to enforce because
    -- it's an API change.
    (LibNameVar, PathTemplate [Ordinary $ prettyShow uid])
  , (PkgIdVar, PathTemplate [Ordinary $ prettyShow pkgId])
  ]

compilerTemplateEnv :: CompilerInfo -> PathTemplateEnv
compilerTemplateEnv compiler =
  [ (CompilerVar, PathTemplate [Ordinary $ prettyShow (compilerInfoId compiler)])
  ]

platformTemplateEnv :: Platform -> PathTemplateEnv
platformTemplateEnv (Platform arch os) =
  [ (OSVar, PathTemplate [Ordinary $ prettyShow os])
  , (ArchVar, PathTemplate [Ordinary $ prettyShow arch])
  ]

abiTemplateEnv :: CompilerInfo -> Platform -> PathTemplateEnv
abiTemplateEnv compiler (Platform arch os) =
  [
    ( AbiVar
    , PathTemplate
        [ Ordinary $
            prettyShow arch
              ++ '-'
              : prettyShow os
              ++ '-'
              : prettyShow (compilerInfoId compiler)
              ++ case compilerInfoAbiTag compiler of
                NoAbiTag -> ""
                AbiTag tag -> '-' : tag
        ]
    )
  , (AbiTagVar, PathTemplate [Ordinary $ abiTagString (compilerInfoAbiTag compiler)])
  ]

installDirsTemplateEnv :: InstallDirs PathTemplate -> PathTemplateEnv
installDirsTemplateEnv dirs =
  [ (PrefixVar, prefix dirs)
  , (BindirVar, bindir dirs)
  , (LibdirVar, libdir dirs)
  , (LibsubdirVar, libsubdir dirs)
  , (DynlibdirVar, dynlibdir dirs)
  , (DatadirVar, datadir dirs)
  , (DatasubdirVar, datasubdir dirs)
  , (DocdirVar, docdir dirs)
  , (HtmldirVar, htmldir dirs)
  ]

-- ---------------------------------------------------------------------------
-- Parsing and showing path templates:

-- The textual format is that of an ordinary Haskell String, eg
-- "$prefix/bin"
-- and this gets parsed to the internal representation as a sequence of path
-- spans which are either strings or variables, eg:
-- PathTemplate [Variable PrefixVar, Ordinary "/bin" ]

instance Show PathTemplate where
  show (PathTemplate template) = show (show template)

instance Read PathTemplate where
  readsPrec p s =
    [ (PathTemplate template, s')
    | (path, s') <- readsPrec p s
    , (template, "") <- reads path
    ]

instance Parsec PathTemplate where
  parsec = parsecPathTemplate

parsecPathTemplate :: CabalParsing m => m PathTemplate
parsecPathTemplate = toPathTemplate <$> parsecFilePath

-- ---------------------------------------------------------------------------
-- Internal utilities

{- FOURMOLU_DISABLE -}
getWindowsProgramFilesDir :: IO FilePath
getWindowsProgramFilesDir = do
#ifdef mingw32_HOST_OS
  m <- shGetFolderPath csidl_PROGRAM_FILES
#else
  let m = Nothing
#endif
  return (fromMaybe "C:\\Program Files" m)
{- FOURMOLU_ENABLE -}

#ifdef mingw32_HOST_OS
shGetFolderPath :: CInt -> IO (Maybe FilePath)
shGetFolderPath n =
  allocaArray long_path_size $ \pPath -> do
     r <- c_SHGetFolderPath nullPtr n nullPtr 0 pPath
     if (r /= 0)
        then return Nothing
        else do s <- peekCWString pPath; return (Just s)
  where
    long_path_size      = 1024 -- MAX_PATH is 260, this should be plenty

csidl_PROGRAM_FILES :: CInt
csidl_PROGRAM_FILES = 0x0026
-- csidl_PROGRAM_FILES_COMMON :: CInt
-- csidl_PROGRAM_FILES_COMMON = 0x002b

{- FOURMOLU_DISABLE -}
#if defined(x86_64_HOST_ARCH) || defined(aarch64_HOST_ARCH)
#define CALLCONV ccall
#else
#define CALLCONV stdcall
#endif

foreign import CALLCONV unsafe "shlobj.h SHGetFolderPathW"
            c_SHGetFolderPath :: Ptr ()
                              -> CInt
                              -> Ptr ()
                              -> CInt
                              -> CWString
                              -> Prelude.IO CInt
#endif
{- FOURMOLU_ENABLE -}

-- ---------------------------------------------------------------------------
-- FieldGrammar

installDirsGrammar :: ParsecFieldGrammar' (InstallDirs (Flag PathTemplate))
installDirsGrammar =
  InstallDirs
    <$> optionalFieldDef "prefix" installDirsPrefixLens mempty
    <*> optionalFieldDef "bindir" installDirsBindirLens mempty
    <*> optionalFieldDef "libdir" installDirsLibdirLens mempty
    <*> optionalFieldDef "libsubdir" installDirsLibsubdirLens mempty
    <*> optionalFieldDef "dynlibdir" installDirsDynlibdirLens mempty
    <*> pure NoFlag -- flibdir
    <*> optionalFieldDef "libexecdir" installDirsLibexecdirLens mempty
    <*> optionalFieldDef "libexecsubdir" installDirsLibexecsubdirLens mempty
    <*> pure NoFlag -- includedir
    <*> optionalFieldDef "datadir" installDirsDatadirLens mempty
    <*> optionalFieldDef "datasubdir" installDirsDatasubdirLens mempty
    <*> optionalFieldDef "docdir" installDirsDocdirLens mempty
    <*> pure NoFlag -- mandir
    <*> optionalFieldDef "htmldir" installDirsHtmldirLens mempty
    <*> optionalFieldDef "haddockdir" installDirsHaddockdirLens mempty
    <*> optionalFieldDef "sysconfdir" installDirsSysconfdirLens mempty

-- ---------------------------------------------------------------------------
-- Lenses

installDirsPrefixLens :: Lens' (InstallDirs a) a
installDirsPrefixLens f c = fmap (\x -> c{prefix = x}) (f (prefix c))
{-# INLINEABLE installDirsPrefixLens #-}

installDirsBindirLens :: Lens' (InstallDirs a) a
installDirsBindirLens f c = fmap (\x -> c{bindir = x}) (f (bindir c))
{-# INLINEABLE installDirsBindirLens #-}

installDirsLibdirLens :: Lens' (InstallDirs a) a
installDirsLibdirLens f c = fmap (\x -> c{libdir = x}) (f (libdir c))
{-# INLINEABLE installDirsLibdirLens #-}

installDirsLibsubdirLens :: Lens' (InstallDirs a) a
installDirsLibsubdirLens f c = fmap (\x -> c{libsubdir = x}) (f (libsubdir c))
{-# INLINEABLE installDirsLibsubdirLens #-}

installDirsDynlibdirLens :: Lens' (InstallDirs a) a
installDirsDynlibdirLens f c = fmap (\x -> c{dynlibdir = x}) (f (dynlibdir c))
{-# INLINEABLE installDirsDynlibdirLens #-}

installDirsLibexecdirLens :: Lens' (InstallDirs a) a
installDirsLibexecdirLens f c = fmap (\x -> c{libexecdir = x}) (f (libexecdir c))
{-# INLINEABLE installDirsLibexecdirLens #-}

installDirsLibexecsubdirLens :: Lens' (InstallDirs a) a
installDirsLibexecsubdirLens f c = fmap (\x -> c{libexecsubdir = x}) (f (libexecsubdir c))
{-# INLINEABLE installDirsLibexecsubdirLens #-}

installDirsDatadirLens :: Lens' (InstallDirs a) a
installDirsDatadirLens f c = fmap (\x -> c{datadir = x}) (f (datadir c))
{-# INLINEABLE installDirsDatadirLens #-}

installDirsDatasubdirLens :: Lens' (InstallDirs a) a
installDirsDatasubdirLens f c = fmap (\x -> c{datasubdir = x}) (f (datasubdir c))
{-# INLINEABLE installDirsDatasubdirLens #-}

installDirsDocdirLens :: Lens' (InstallDirs a) a
installDirsDocdirLens f c = fmap (\x -> c{docdir = x}) (f (docdir c))
{-# INLINEABLE installDirsDocdirLens #-}

installDirsHtmldirLens :: Lens' (InstallDirs a) a
installDirsHtmldirLens f c = fmap (\x -> c{htmldir = x}) (f (htmldir c))
{-# INLINEABLE installDirsHtmldirLens #-}

installDirsHaddockdirLens :: Lens' (InstallDirs a) a
installDirsHaddockdirLens f c = fmap (\x -> c{haddockdir = x}) (f (haddockdir c))
{-# INLINEABLE installDirsHaddockdirLens #-}

installDirsSysconfdirLens :: Lens' (InstallDirs a) a
installDirsSysconfdirLens f c = fmap (\x -> c{sysconfdir = x}) (f (sysconfdir c))
{-# INLINEABLE installDirsSysconfdirLens #-}
