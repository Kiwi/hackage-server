{-# LANGUAGE DeriveDataTypeable, GeneralizedNewtypeDeriving #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  Distribution.Client.Reporting
-- Copyright   :  (c) David Waern 2008
-- License     :  BSD-like
--
-- Maintainer  :  david.waern@gmail.com
-- Stability   :  experimental
-- Portability :  portable
--
-- Anonymous build report data structure, printing and parsing
--
-----------------------------------------------------------------------------
module Distribution.Server.Features.BuildReports.BuildReport (
    BuildReport(..),
    InstallOutcome(..),
    Outcome(..),

    -- * parsing and pretty printing
    read,
    parse,
    parseList,
    show,
    showList,
  ) where

import Distribution.Package
         ( PackageIdentifier )
import Distribution.PackageDescription
         ( FlagName(..), FlagAssignment )
--import Distribution.Version
--         ( Version )
import Distribution.System
         ( OS, Arch )
import Distribution.Compiler
         ( CompilerId )
import qualified Distribution.Text as Text
         ( Text(disp, parse) )
import Distribution.ParseUtils
         ( FieldDescr(..), ParseResult(..), Field(..)
         , simpleField, listField, readFields
         , syntaxError, locatedErrorMsg, showFields )
import Distribution.Simple.Utils
         ( comparing )
import Distribution.Server.Util.Merge

import qualified Distribution.Compat.ReadP as Parse
         ( ReadP, pfail, munch1, skipSpaces )
import qualified Text.PrettyPrint.HughesPJ as Disp
         ( Doc, char, text )
import Text.PrettyPrint.HughesPJ
         ( (<+>), (<>) )

import Data.List
         ( unfoldr, sortBy )
import Data.Char as Char
         ( isAlpha, isAlphaNum )
import Data.Typeable
         ( Typeable )

import Prelude hiding (show, read)

data BuildReport
   = BuildReport {
    -- | The package this build report is about
    package         :: PackageIdentifier,

    -- | The OS and Arch the package was built on
    os              :: OS,
    arch            :: Arch,

    -- | The Haskell compiler (and hopefully version) used
    compiler        :: CompilerId,

    -- | The uploading client, ie cabal-install-x.y.z
    client          :: PackageIdentifier,

    -- | Which configurations flags we used
    flagAssignment  :: FlagAssignment,

    -- | Which dependent packages we were using exactly
    dependencies    :: [PackageIdentifier],

    -- | Did installing work ok?
    installOutcome  :: InstallOutcome,

    --   Which version of the Cabal library was used to compile the Setup.hs
--    cabalVersion    :: Version,

    --   Which build tools we were using (with versions)
--    tools      :: [PackageIdentifier],

    -- | Configure outcome, did configure work ok?
    docsOutcome     :: Outcome,

    -- | Configure outcome, did configure work ok?
    testsOutcome    :: Outcome
  }
  deriving (Eq, Typeable, Show)

data InstallOutcome
   = DependencyFailed PackageIdentifier
   | DownloadFailed
   | UnpackFailed
   | SetupFailed
   | ConfigureFailed
   | BuildFailed
   | InstallFailed
   | InstallOk
   deriving (Eq, Show)

data Outcome = NotTried | Failed | Ok deriving (Eq, Show)

-- ------------------------------------------------------------
-- * External format
-- ------------------------------------------------------------

initialBuildReport :: BuildReport
initialBuildReport = BuildReport {
    package         = requiredField "package",
    os              = requiredField "os",
    arch            = requiredField "arch",
    compiler        = requiredField "compiler",
    client          = requiredField "client",
    flagAssignment  = [],
    dependencies    = [],
    installOutcome  = requiredField "install-outcome",
--    cabalVersion  = Nothing,
--    tools         = [],
    docsOutcome     = NotTried,
    testsOutcome    = NotTried
  }
  where
    requiredField fname = error ("required field: " ++ fname)

-- -----------------------------------------------------------------------------
-- Parsing

read :: String -> BuildReport
read s = case parse s of
  Left  err -> error $ "error parsing build report: " ++ err
  Right rpt -> rpt

parse :: Monad m => String -> m BuildReport
parse s = case parseFields s of
  ParseFailed perror -> fail msg where (_, msg) = locatedErrorMsg perror
  ParseOk   _ report -> return report

--FIXME: this does not allow for optional or repeated fields
parseFields :: String -> ParseResult BuildReport
parseFields input = do
  fields <- mapM extractField =<< readFields input
  let merged = mergeBy (\desc (_,name,_) -> compare (fieldName desc) name)
                       sortedFieldDescrs
                       (sortBy (comparing (\(_,name,_) -> name)) fields)
  checkMerged initialBuildReport merged

  where
    extractField :: Field -> ParseResult (Int, String, String)
    extractField (F line name value)  = return (line, name, value)
    extractField (Section line _ _ _) = syntaxError line "Unrecognized stanza"
    extractField (IfBlock line _ _ _) = syntaxError line "Unrecognized stanza"

    checkMerged report [] = return report
    checkMerged report (merged:remaining) = case merged of
      InBoth fieldDescr (line, _name, value) -> do
        report' <- fieldSet fieldDescr line value report
        checkMerged report' remaining
      OnlyInRight (line, name, _) ->
        syntaxError line ("Unrecognized field " ++ name)
      OnlyInLeft  fieldDescr ->
        fail ("Missing field " ++ fieldName fieldDescr)

parseList :: String -> [BuildReport]
parseList str =
  [ report | Right report <- map parse (split str) ]

  where
    split :: String -> [String]
    split = filter (not . null) . unfoldr chunk . lines
    chunk [] = Nothing
    chunk ls = case break null ls of
                 (r, rs) -> Just (unlines r, dropWhile null rs)

-- -----------------------------------------------------------------------------
-- Pretty-printing

show :: BuildReport -> String
show = showFields fieldDescrs

-- -----------------------------------------------------------------------------
-- Description of the fields, for parsing/printing

fieldDescrs :: [FieldDescr BuildReport]
fieldDescrs =
 [ simpleField "package"         Text.disp      Text.parse
                                 package        (\v r -> r { package = v })
 , simpleField "os"              Text.disp      Text.parse
                                 os             (\v r -> r { os = v })
 , simpleField "arch"            Text.disp      Text.parse
                                 arch           (\v r -> r { arch = v })
 , simpleField "compiler"        Text.disp      Text.parse
                                 compiler       (\v r -> r { compiler = v })
 , simpleField "client"          Text.disp      Text.parse
                                 client         (\v r -> r { client = v })
 , listField   "flags"           dispFlag       parseFlag
                                 flagAssignment (\v r -> r { flagAssignment = v })
 , listField   "dependencies"    Text.disp      Text.parse
                                 dependencies   (\v r -> r { dependencies = v })
 , simpleField "install-outcome" Text.disp      Text.parse
                                 installOutcome (\v r -> r { installOutcome = v })
 , simpleField "docs-outcome"    Text.disp      Text.parse
                                 docsOutcome    (\v r -> r { docsOutcome = v })
 , simpleField "tests-outcome"   Text.disp      Text.parse
                                 testsOutcome   (\v r -> r { testsOutcome = v })
 ]

sortedFieldDescrs :: [FieldDescr BuildReport]
sortedFieldDescrs = sortBy (comparing fieldName) fieldDescrs

dispFlag :: (FlagName, Bool) -> Disp.Doc
dispFlag (FlagName name, True)  =                  Disp.text name
dispFlag (FlagName name, False) = Disp.char '-' <> Disp.text name

parseFlag :: Parse.ReadP r (FlagName, Bool)
parseFlag = do
  name <- Parse.munch1 (\c -> Char.isAlphaNum c || c == '_' || c == '-')
  case name of
    ('-':flag) -> return (FlagName flag, False)
    flag       -> return (FlagName flag, True)

instance Text.Text InstallOutcome where
  disp (DependencyFailed pkgid) = Disp.text "DependencyFailed" <+> Text.disp pkgid
  disp DownloadFailed  = Disp.text "DownloadFailed"
  disp UnpackFailed    = Disp.text "UnpackFailed"
  disp SetupFailed     = Disp.text "SetupFailed"
  disp ConfigureFailed = Disp.text "ConfigureFailed"
  disp BuildFailed     = Disp.text "BuildFailed"
  disp InstallFailed   = Disp.text "InstallFailed"
  disp InstallOk       = Disp.text "InstallOk"

  parse = do
    name <- Parse.munch1 Char.isAlphaNum
    case name of
      "DependencyFailed" -> do Parse.skipSpaces
                               pkgid <- Text.parse
                               return (DependencyFailed pkgid)
      "DownloadFailed"   -> return DownloadFailed
      "UnpackFailed"     -> return UnpackFailed
      "SetupFailed"      -> return SetupFailed
      "ConfigureFailed"  -> return ConfigureFailed
      "BuildFailed"      -> return BuildFailed
      "InstallFailed"    -> return InstallFailed
      "InstallOk"        -> return InstallOk
      _                  -> Parse.pfail

instance Text.Text Outcome where
  disp NotTried = Disp.text "NotTried"
  disp Failed   = Disp.text "Failed"
  disp Ok       = Disp.text "Ok"
  parse = do
    name <- Parse.munch1 Char.isAlpha
    case name of
      "NotTried" -> return NotTried
      "Failed"   -> return Failed
      "Ok"       -> return Ok
      _          -> Parse.pfail
