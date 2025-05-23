-- |
--
-- This modules provides functions for working with both the legacy
-- "build-tools" field, and its replacement, "build-tool-depends". Prefer using
-- the functions contained to access those fields directly.
module Distribution.Simple.BuildToolDepends where

import Distribution.Compat.Prelude
import Prelude ()

import qualified Data.Map as Map

import Distribution.Package
import Distribution.PackageDescription

-- | Same as 'desugarBuildTool', but requires atomic information (package
-- name, executable names) instead of a whole 'PackageDescription'.
desugarBuildToolSimple
  :: PackageName
  -> [UnqualComponentName]
  -> LegacyExeDependency
  -> Maybe ExeDependency
desugarBuildToolSimple pname exeNames (LegacyExeDependency name reqVer)
  | foundLocal = Just $ ExeDependency pname toolName reqVer
  | otherwise = Map.lookup name allowMap
  where
    toolName = mkUnqualComponentName name
    foundLocal = toolName `elem` exeNames
    allowlist =
      [ "hscolour"
      , "haddock"
      , "happy"
      , "alex"
      , "hsc2hs"
      , "c2hs"
      , "cpphs"
      , "hspec-discover"
      ]
    allowMap = Map.fromList $ flip map allowlist $ \n ->
      (n, ExeDependency (mkPackageName n) (mkUnqualComponentName n) reqVer)

-- | Desugar a "build-tools" entry into a proper executable dependency if
-- possible.
--
-- An entry can be so desugared in two cases:
--
-- 1. The name in build-tools matches a locally defined executable.  The
--    executable dependency produced is on that exe in the current package.
--
-- 2. The name in build-tools matches a hard-coded set of known tools.  For now,
--    the executable dependency produced is one an executable in a package of
--    the same, but the hard-coding could just as well be per-key.
--
-- The first cases matches first.
desugarBuildTool
  :: PackageDescription
  -> LegacyExeDependency
  -> Maybe ExeDependency
desugarBuildTool pkg led =
  desugarBuildToolSimple
    (packageName pkg)
    (map exeName $ executables pkg)
    led

-- | Get everything from "build-tool-depends", along with entries from
-- "build-tools" that we know how to desugar.
--
-- This should almost always be used instead of just accessing the
-- `buildToolDepends` field directly.
getAllToolDependencies
  :: PackageDescription
  -> BuildInfo
  -> [ExeDependency]
getAllToolDependencies pkg bi =
  buildToolDepends bi ++ mapMaybe (desugarBuildTool pkg) (buildTools bi)

-- | Does the given executable dependency map to this current package?
--
-- This is a tiny function, but used in a number of places.
--
-- This function is only sound to call on `BuildInfo`s from the given package
-- description. This is because it just filters the package names of each
-- dependency, and does not check whether version bounds in fact exclude the
-- current package, or the referenced components in fact exist in the current
-- package.
--
-- This is OK because when a package is loaded, it is checked (in
-- `Distribution.Package.Check`) that dependencies matching internal components
-- do indeed have version bounds accepting the current package, and any
-- depended-on component in the current package actually exists. In fact this
-- check is performed by gathering the internal tool dependencies of each
-- component of the package according to this module, and ensuring those
-- properties on each so-gathered dependency.
--
-- version bounds and components of the package are unchecked. This is because
-- we sanitize exe deps so that the matching name implies these other
-- conditions.
isInternal :: PackageDescription -> ExeDependency -> Bool
isInternal pkg (ExeDependency n _ _) = n == packageName pkg

-- | Get internal "build-tool-depends", along with internal "build-tools"
--
-- This is a tiny function, but used in a number of places. The same
-- restrictions that apply to `isInternal` also apply to this function.
getAllInternalToolDependencies
  :: PackageDescription
  -> BuildInfo
  -> [UnqualComponentName]
getAllInternalToolDependencies pkg bi =
  [ toolname
  | dep@(ExeDependency _ toolname _) <- getAllToolDependencies pkg bi
  , isInternal pkg dep
  ]
