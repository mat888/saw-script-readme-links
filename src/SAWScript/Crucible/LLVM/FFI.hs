{-# LANGUAGE BlockArguments    #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE ViewPatterns      #-}

module SAWScript.Crucible.LLVM.FFI
  ( llvm_ffi_setup
  ) where

import           Control.Monad
import           Control.Monad.Trans
import           Data.Bits                            (finiteBitSize)
import           Data.Foldable
import           Data.List
import qualified Data.Map                             as Map
import           Data.Maybe
import           Data.Text                            (Text)
import qualified Data.Text                            as Text
import           Foreign.C.Types                      (CSize)

import qualified Text.LLVM.AST                        as LLVM

import           Cryptol.Eval.Type
import           Cryptol.TypeCheck.FFI.FFIType
import           Cryptol.TypeCheck.Solver.InfNat
import           Cryptol.TypeCheck.Type
import           Cryptol.Utils.Ident
import           Cryptol.Utils.PP                     (pretty)
import           Cryptol.Utils.RecordMap

import           SAWScript.Builtins
import           SAWScript.Crucible.Common.MethodSpec
import           SAWScript.Crucible.LLVM.Builtins
import           SAWScript.Crucible.LLVM.MethodSpecIR
import           SAWScript.LLVMBuiltins
import           SAWScript.Value
import           Verifier.SAW.CryptolEnv
import           Verifier.SAW.OpenTerm
import           Verifier.SAW.Recognizer
import           Verifier.SAW.SharedTerm
import           Verifier.SAW.TypedTerm

-- | Generate a @LLVMSetup@ spec that can be used to verify the given term
-- containing a Cryptol foreign function fully applied to any type arguments.
llvm_ffi_setup :: TypedTerm -> LLVMCrucibleSetupM ()
llvm_ffi_setup appTypedTerm = do
  cryEnv <- lll $ rwCryptol <$> getMergedEnv
  sc <- lll getSharedContext
  case asConstant funTerm of
    Just (ec, funDef)
      | Just FFIFunType {..} <- Map.lookup (ecName ec) (eFFITypes cryEnv) -> do
        when (isNothing funDef) do
          throw "Cannot verify foreign function with no Cryptol implementation"
        tenv <- buildTypeEnv ffiTParams tyArgTerms
        sizeArgs <- lio $ traverse (mkSizeArg sc) tyArgTerms
        (argTerms, inArgss) <- unzip <$> zipWithM
          (\i -> setupInArg sc tenv ("in" <> Text.pack (show i)))
          [0 :: Integer ..]
          ffiArgTypes
        let inArgs = concat inArgss
        (outArgs, post) <- setupRet sc tenv ffiRetType
        llvm_execute_func (sizeArgs ++ inArgs ++ outArgs)
        ret <- lio $ completeOpenTerm sc $
          applyOpenTermMulti (closedOpenTerm appTerm)
            (map closedOpenTerm argTerms)
        post ret
    _ ->
      throw "Not a (monomorphic instantiation of a) Cryptol foreign function"

  where

  appTerm = ttTerm appTypedTerm
  (funTerm, tyArgTerms) = asApplyAll appTerm

  throw :: String -> LLVMCrucibleSetupM a
  throw msg = do
    funTermStr <- lll $ show_term funTerm
    throwLLVM' "llvm_ffi_setup" $
      "Cannot generate FFI setup for " ++ funTermStr ++ ":\n" ++ msg

  buildTypeEnv :: [TParam] -> [Term] -> LLVMCrucibleSetupM TypeEnv
  buildTypeEnv [] [] = pure mempty
  buildTypeEnv (param:params) (argTerm:argTerms) =
    case asCtorParams argTerm of
      Just (primName -> "Cryptol.TCNum", [], [asNat -> Just n]) ->
        bindTypeVar (TVBound param) (Left (Nat (toInteger n))) <$>
          buildTypeEnv params argTerms
      _ -> do
        argTermStr <- lll $ show_term argTerm
        throw $ "Not a numeric literal type argument: " ++ argTermStr
  buildTypeEnv params [] = throw $
    "Foreign function not fully instantiated;\n"
    ++ "Missing type arguments for: " ++ intercalate ", " (map pretty params)
  buildTypeEnv [] _ = throw "Too many arguments"

  mkSizeArg :: SharedContext -> Term -> IO (AllLLVM SetupValue)
  mkSizeArg sc tyArgTerm = do
    sizeTerm <- completeOpenTerm sc $
      applyGlobalOpenTerm "Cryptol.ecNumber"
        [ closedOpenTerm tyArgTerm
        , vectorTypeOpenTerm sizeBitSize boolTypeOpenTerm
        , applyGlobalOpenTerm "Cryptol.PLiteralSeqBool"
            [ctorOpenTerm "Cryptol.TCNum" [sizeBitSize]]
        ]
    anySetupTerm <$> mkTypedTerm sc sizeTerm
    where
    sizeBitSize = natOpenTerm $
      fromIntegral $ finiteBitSize (undefined :: CSize)

  setupInArg :: SharedContext -> TypeEnv -> Text -> FFIType ->
    LLVMCrucibleSetupM (Term, [AllLLVM SetupValue])
  setupInArg sc tenv = go
    where
    go name ffiType =
      case ffiType of
        FFIBool -> throw "Bit not supported"
        FFIBasic ffiBasicType -> do
          llvmType <- convertBasicType ffiBasicType
          x <- llvm_fresh_var name llvmType
          pure (ttTerm x, [anySetupTerm x])
        FFIArray lengths ffiBasicType -> do
          len <- getArrayLen tenv lengths
          llvmType <- convertBasicType ffiBasicType
          let arrType = llvm_array len llvmType
          arr <- llvm_fresh_var name arrType
          ptr <- llvm_alloc_readonly arrType
          llvm_points_to True ptr (anySetupTerm arr)
          pure (ttTerm arr, [ptr])
        FFITuple ffiTypes ->
          tupleInArgs =<< zipWithM
            (\i -> go (name <> "." <> Text.pack (show i)))
            [0 :: Integer ..]
            ffiTypes
        FFIRecord ffiTypeMap ->
          tupleInArgs =<< traverse
            (\(field, ty) -> go (name <> "." <> identText field) ty)
            (displayFields ffiTypeMap)
    tupleInArgs (unzip -> (terms, inArgss)) = do
      tupleTerm <- lio $ completeOpenTerm sc $
        tupleOpenTerm' $ map closedOpenTerm terms
      pure (tupleTerm, concat inArgss)

  setupRet :: SharedContext -> TypeEnv -> FFIType ->
    LLVMCrucibleSetupM ([AllLLVM SetupValue], Term -> LLVMCrucibleSetupM ())
  setupRet sc tenv ffiType =
    case ffiType of
      FFIBool -> throw "Bit not supported"
      FFIBasic _ -> do
        let post ret = do
              retSetupValue <- lio $ anySetupTerm <$> mkTypedTerm sc ret
              llvm_return retSetupValue
        pure ([], post)
      _ -> setupOutArg sc tenv ffiType

  setupOutArg :: SharedContext -> TypeEnv -> FFIType ->
    LLVMCrucibleSetupM ([AllLLVM SetupValue], Term -> LLVMCrucibleSetupM ())
  setupOutArg sc tenv = go
    where
    go ffiType =
      case ffiType of
        FFIBool -> throw "Bit not supported"
        FFIBasic ffiBasicType -> do
          llvmType <- convertBasicType ffiBasicType
          simpleOutArg llvmType
        FFIArray lengths ffiBasicType -> do
          len <- getArrayLen tenv lengths
          llvmType <- convertBasicType ffiBasicType
          simpleOutArg (llvm_array len llvmType)
        FFITuple ffiTypes -> tupleOutArgs ffiTypes
        FFIRecord ffiTypeMap -> tupleOutArgs (recordElements ffiTypeMap)
    simpleOutArg llvmType = do
      ptr <- llvm_alloc llvmType
      let post ret = do
            retSetupValue <- lio $ anySetupTerm <$> mkTypedTerm sc ret
            llvm_points_to True ptr retSetupValue
      pure ([ptr], post)
    tupleOutArgs ffiTypes = do
      (outArgss, posts) <- mapAndUnzipM go ffiTypes
      let len = fromIntegral $ length ffiTypes
          post ret =
            for_ (zip [0..] posts) \(i, p) -> do
              ret' <- lio $ completeOpenTerm sc $
                projTupleOpenTerm' i len (closedOpenTerm ret)
              p ret'
      pure (concat outArgss, post)

  getArrayLen :: TypeEnv -> [Type] -> LLVMCrucibleSetupM Int
  getArrayLen tenv lengths =
    case lengths of
      [len] -> pure $ fromInteger $ finNat' $ evalNumType tenv len
      _     -> throw "Multidimensional arrays not supported"

  convertBasicType :: FFIBasicType -> LLVMCrucibleSetupM LLVM.Type
  convertBasicType (FFIBasicVal ffiBasicValType) =
    case ffiBasicValType of
      FFIWord n ffiWordSize
        | n == size -> pure $ llvm_int size
        | otherwise -> throw
          "Only exact machine-sized bitvectors (8, 16, 32, 64 bits) supported"
        where
        size :: Integral a => a
        size =
          case ffiWordSize of
            FFIWord8  -> 8
            FFIWord16 -> 16
            FFIWord32 -> 32
            FFIWord64 -> 64
      FFIFloat _ _ ffiFloatSize -> pure
        case ffiFloatSize of
          FFIFloat32 -> llvm_float
          FFIFloat64 -> llvm_double
  convertBasicType (FFIBasicRef _) =
    throw "GMP types (Integer, Z) not supported"

lll :: TopLevel a -> LLVMCrucibleSetupM a
lll x = LLVMCrucibleSetupM $ lift $ lift x

lio :: IO a -> LLVMCrucibleSetupM a
lio x = LLVMCrucibleSetupM $ liftIO x
