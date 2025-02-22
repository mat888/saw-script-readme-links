{-# LANGUAGE CPP #-}
{- |
Module      : Main
Description :
License     : BSD3
Maintainer  : atomb
Stability   : provisional
-}
module Main where

import Control.Exception
import Control.Monad
import Data.Maybe

import System.IO
import System.Console.GetOpt
import System.Environment
import System.Directory

import GHC.IO.Encoding (setLocaleEncoding)

import SAWScript.Options
import SAWScript.Utils
import SAWScript.Interpreter (processFile)
import qualified SAWScript.REPL as REPL
import qualified SAWScript.REPL.Haskeline as REPL
import qualified SAWScript.REPL.Monad as REPL
import SAWScript.Version (shortVersionText)
import SAWScript.Value (AIGProxy(..))
import SAWScript.SolverCache
import SAWScript.SolverVersions
import qualified Data.AIG.CompactGraph as AIG

main :: IO ()
main = do
  setLocaleEncoding utf8
  hSetBuffering stdout LineBuffering
  argv <- getArgs
  case getOpt Permute options argv of
    (opts, files, []) -> do
      opts' <- foldl (>>=) (return defaultOptions) opts
      opts'' <- processEnv opts'
      {- We have two modes of operation: batch processing, handled in
      'SAWScript.ProcessFile', and a REPL, defined in 'SAWScript.REPL'. -}
      case files of
        _ | showVersion opts'' -> hPutStrLn stderr shortVersionText
        _ | showHelp opts'' -> err opts'' (usageInfo header options)
        _ | Just path <- cleanMisVsCache opts'' -> doCleanMisVsCache opts'' path
        [] -> checkZ3 opts'' *> REPL.run opts''
        _ | runInteractively opts'' -> checkZ3 opts'' *> REPL.run opts''
        [file] -> checkZ3 opts'' *>
          processFile (AIGProxy AIG.compactProxy) opts'' file subsh proofSubsh`catch`
          (\(ErrorCall msg) -> err opts'' msg)
        (_:_) -> err opts'' "Multiple files not yet supported."
    (_, _, errs) -> do hPutStrLn stderr (concat errs ++ usageInfo header options)
                       exitProofUnknown
  where subsh = Just (REPL.subshell (REPL.replBody Nothing (return ())))
        proofSubsh = Just (REPL.proof_subshell (REPL.replBody Nothing (return ())))
        header = "Usage: saw [OPTION...] [-I | file]"
        checkZ3 opts = do
          p <- findExecutable "z3"
          unless (isJust p)
            $ err opts "Error: z3 is required to run SAW, but it was not found on the system path."
        err opts msg = do
          when (verbLevel opts >= Error)
            (hPutStrLn stderr msg)
          exitProofUnknown
        doCleanMisVsCache opts path | not (null path) = do
          cache <- lazyOpenSolverCache path
          vs <- getSolverBackendVersions allBackends
          fst <$> solverCacheOp (cleanMismatchedVersionsSolverCache vs) opts cache
        doCleanMisVsCache opts _ =
          err opts "Error: either --clean-mismatched-versions-solver-cache must be given an argument or SAW_SOLVER_CACHE_PATH must be set"

