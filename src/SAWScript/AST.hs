{- |
Module      : SAWScript.AST
Description : Datatypes representing SAWScript statements, expressions, and types.
License     : BSD3
Maintainer  : huffman
Stability   : provisional
-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveFunctor,DeriveFoldable,DeriveTraversable #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE NamedFieldPuns #-}

module SAWScript.AST
       ( Name
       , LName
       , Located(..)
       , Import(..)
       , Expr(..)
       , Pattern(..)
       , Stmt(..)
       , DeclGroup(..)
       , Decl(..)
       , Context(..)
       , Type(..), TypeIndex
       , TyCon(..)
       , Schema(..)
       , toLName
       , tMono, tForall, tTuple, tRecord, tArray, tFun
       , tString, tTerm, tType, tBool, tInt, tAIG, tCFG
       , tJVMSpec, tLLVMSpec, tMIRSpec
       , tBlock, tContext, tVar
       , isContext

       , PrettyPrint(..), pShow, commaSepAll, prettyWholeModule
       ) where

import SAWScript.Token
import SAWScript.Position (Pos(..), Positioned(..), maxSpan)

import Data.Map (Map)
import qualified Data.Map as Map
import Data.List (intercalate)

#if !MIN_VERSION_base(4,8,0)
import Data.Foldable (Foldable)
import Data.Traversable (Traversable)
#endif
import qualified Prettyprinter as PP
import           Prettyprinter (Pretty)

import qualified Cryptol.Parser.AST as P (ImportSpec(..), ModName)
import qualified Cryptol.Utils.Ident as P (identText, modNameChunks)

-- Names {{{

type Name = String

-- }}}

-- Location tracking {{{

--
-- Type to wrap a thing with a position
--
-- This is declared with record syntax to provide accessors/projection
-- functions; it is intended to be used positionally.
--
data Located a = Located {
  getVal :: a,          -- the thing
  getOrig :: Name,      -- a name/string for it, where applicable
  locatedPos :: Pos     -- the position
} deriving (Functor, Foldable, Traversable)

instance Show (Located a) where
  show (Located _ v p) = show v ++ " (" ++ show p ++ ")"

instance Positioned (Located a) where
  getPos = locatedPos

instance Eq a => Eq (Located a) where
  a == b = getVal a == getVal b

instance Ord a => Ord (Located a) where
  compare a b = compare (getVal a) (getVal b)

type LName = Located Name

toLName :: Token Pos -> LName
toLName p = Located (tokStr p) (tokStr p) (tokPos p)

-- }}}

-- Expr Level {{{

data Import = Import
  { iModule    :: Either FilePath P.ModName
  , iAs        :: Maybe P.ModName
  , iSpec      :: Maybe P.ImportSpec
  , iPos       :: Pos
  } deriving Show

instance Positioned Import where
  getPos = iPos

data Expr
  -- Constants
  = Bool Pos Bool
  | String Pos String
  | Int Pos Integer
  | Code (Located String)
  | CType (Located String)
  -- Structures
  | Array  Pos [Expr]
  | Block  Pos [Stmt]
  | Tuple  Pos [Expr]
  | Record Pos (Map Name Expr)
  -- Accessors
  | Index   Pos Expr Expr
  | Lookup  Pos Expr Name
  | TLookup Pos Expr Integer
  -- LC
  | Var (Located Name)
  | Function Pos Pattern Expr
  | Application Pos Expr Expr
  -- Sugar
  | Let Pos DeclGroup Expr
  | TSig Pos Expr Type
  | IfThenElse Pos Expr Expr Expr
  deriving Show

instance Positioned Expr where
  getPos (Bool pos _) = pos
  getPos (String pos _) = pos
  getPos (Int pos _) = pos
  getPos (Code c) = getPos c
  getPos (CType t) = getPos t
  getPos (Array pos _) = pos
  getPos (Block pos _) = pos
  getPos (Tuple pos _) = pos
  getPos (Record pos _) = pos
  getPos (Index pos _ _) = pos
  getPos (Lookup pos _ _) = pos
  getPos (TLookup pos _ _) = pos
  getPos (Var n) = getPos n
  getPos (Function pos _ _) = pos
  getPos (Application pos _ _) = pos
  getPos (Let pos _ _) = pos
  getPos (TSig pos _ _) = pos
  getPos (IfThenElse pos _ _ _) = pos

data Pattern
  = PWild Pos (Maybe Type)
  | PVar Pos LName (Maybe Type)
  | PTuple Pos [Pattern]
  deriving Show

instance Positioned Pattern where
  getPos (PWild pos _) = pos
  getPos (PVar pos _ _) = pos
  getPos (PTuple pos _) = pos

data Stmt
  = StmtBind     Pos Pattern (Maybe Type) Expr
  | StmtLet      Pos DeclGroup
  | StmtCode     Pos (Located String)
  | StmtImport   Pos Import
  | StmtTypedef  Pos (Located String) Type
  deriving Show

instance Positioned Stmt where
  getPos (StmtBind pos _ _ _)  = pos
  getPos (StmtLet pos _)       = pos
  getPos (StmtCode pos _)      = pos
  getPos (StmtImport pos _)    = pos
  getPos (StmtTypedef pos _ _) = pos

data DeclGroup
  = Recursive [Decl]
  | NonRecursive Decl
  deriving Show

instance Positioned DeclGroup where
  getPos (Recursive ds) = maxSpan ds
  getPos (NonRecursive d) = getPos d

data Decl
  = Decl { dPos :: Pos, dPat :: Pattern, dType :: Maybe Schema, dDef :: Expr }
  deriving Show

instance Positioned Decl where
  getPos = dPos

-- }}}

-- Type Level {{{

data Context
  = CryptolSetup
  | JavaSetup
  | LLVMSetup
  | MIRSetup
  | ProofScript
  | TopLevel
  | CrucibleSetup
  deriving (Eq,Show)

data Type
  = TyCon TyCon [Type]
  | TyRecord (Map Name Type)
  | TyVar Name
  | TyUnifyVar TypeIndex       -- ^ For internal typechecker use only
  | TySkolemVar Name TypeIndex -- ^ For internal typechecker use only
  | LType Pos Type
  deriving Show

instance Positioned Type where
  getPos (LType pos _) = pos
  getPos _ = Unknown

type TypeIndex = Integer

data TyCon
  = TupleCon Integer
  | ArrayCon
  | FunCon
  | StringCon
  | TermCon
  | TypeCon
  | BoolCon
  | IntCon
  | BlockCon
  | AIGCon
  | CFGCon
  | JVMSpecCon
  | LLVMSpecCon
  | MIRSpecCon
  | ContextCon Context
  deriving (Eq, Show)

data Schema = Forall [Name] Type
  deriving Show

-- }}}

-- Pretty Printing {{{

prettyWholeModule :: [Stmt] -> PP.Doc ann
prettyWholeModule = (PP.<> PP.line') . vcatWithSemi . map PP.pretty

vcatWithSemi :: [PP.Doc ann] -> PP.Doc ann
vcatWithSemi = PP.vcat . map (PP.<> PP.semi)

instance Pretty Expr where
  pretty expr0 = case expr0 of
    Bool _ b   -> PP.viaShow b
    String _ s -> PP.dquotes (PP.pretty s)
    Int _ i    -> PP.pretty i
    Code ls    -> PP.braces . PP.braces $ PP.pretty (getVal ls)
    CType (Located string _ _) -> PP.braces . PP.pretty $ "|" ++ string ++ "|"
    Array _ xs -> PP.list (map PP.pretty xs)
    Block _ stmts ->
      "do" PP.<+> PP.lbrace PP.<> PP.line' PP.<>
      (PP.indent 3 $ (PP.align . vcatWithSemi . map PP.pretty $ stmts)) PP.<>
      PP.line' PP.<> PP.rbrace
    Tuple _ exprs -> PP.tupled (map PP.pretty exprs)
    Record _ mapping ->
      PP.braces . (PP.space PP.<>) . (PP.<> PP.space) . PP.align . PP.sep . PP.punctuate PP.comma $
      map (\(name, value) -> PP.pretty name PP.<+> "=" PP.<+> PP.pretty value)
      (Map.assocs mapping)
    Index _ _ _ -> error "No concrete syntax for AST node 'Index'"
    Lookup _ expr name -> PP.pretty expr PP.<> PP.dot PP.<> PP.pretty name
    TLookup _ expr int -> PP.pretty expr PP.<> PP.dot PP.<> PP.pretty int
    Var (Located name _ _) ->
      PP.pretty name
    Function _ pat expr ->
      "\\" PP.<+> PP.pretty pat PP.<+> "->" PP.<+> PP.pretty expr
    -- FIXME, use precedence to minimize parentheses
    Application _ f a -> PP.parens (PP.pretty f PP.<+> PP.pretty a)
    Let _ (NonRecursive decl) expr ->
      PP.fillSep
      [ "let" PP.<+> prettyDef decl
      , "in" PP.<+> PP.pretty expr
      ]
    Let _ (Recursive decls) expr ->
      PP.fillSep
      [ "let" PP.<+>
        PP.cat (PP.punctuate
                (PP.fillSep [PP.emptyDoc, "and" PP.<> PP.space])
                (map prettyDef decls))
      , "in" PP.<+> PP.pretty expr
      ]
    TSig _ expr typ -> PP.parens $ PP.pretty expr PP.<+> PP.colon PP.<+> pretty 0 typ
    IfThenElse _ e1 e2 e3 ->
      "if" PP.<+> PP.pretty e1 PP.<+>
      "then" PP.<+> PP.pretty e2 PP.<+>
      "else" PP.<+> PP.pretty e3

instance PrettyPrint Expr where
  pretty _ e = PP.pretty e

instance Pretty Pattern where
  pretty pat = case pat of
    PWild _ mType ->
      prettyMaybeTypedArg ("_", mType)
    PVar _ (Located name _ _) mType ->
      prettyMaybeTypedArg (name, mType)
    PTuple _ pats ->
      PP.tupled (map PP.pretty pats)

instance Pretty Stmt where
   pretty = \case
      StmtBind _ (PWild _ _leftType) _rightType expr ->
         PP.pretty expr
      StmtBind _ pat _rightType expr ->
         PP.pretty pat PP.<+> "<-" PP.<+> PP.align (PP.pretty expr)
      StmtLet _ (NonRecursive decl) ->
         "let" PP.<+> prettyDef decl
      StmtLet _ (Recursive decls) ->
         "rec" PP.<+>
         PP.cat (PP.punctuate
            (PP.fillSep [PP.emptyDoc, "and" PP.<> PP.space])
            (map prettyDef decls))
      StmtCode _ (Located code _ _) ->
         "let" PP.<+>
            (PP.braces . PP.braces $ PP.pretty code)
      StmtImport _ Import{iModule,iAs,iSpec} ->
         "import" PP.<+>
         (case iModule of
            Left filepath ->
               PP.dquotes . PP.pretty $ filepath
            Right modName ->
               ppModName modName) PP.<>
         (case iAs of
            Just modName ->
               PP.space PP.<> "as" PP.<+> ppModName modName
            Nothing -> PP.emptyDoc) PP.<>
         (case iSpec of
            Just (P.Hiding names) ->
               PP.space PP.<> "hiding" PP.<+> PP.tupled (map ppIdent names)
            Just (P.Only names) ->
               PP.space PP.<> PP.tupled (map ppIdent names)
            Nothing -> PP.emptyDoc)
      StmtTypedef _ (Located name _ _) ty ->
         "typedef" PP.<+> PP.pretty name PP.<+> pretty 0 ty
      --expr -> PP.cyan . PP.viaShow expr

      where
        ppModName mn = PP.pretty (intercalate "." (P.modNameChunks mn))
        ppIdent i = PP.pretty (P.identText i)
        --ppName n = ppIdent (P.nameIdent n)

prettyDef :: Decl -> PP.Doc ann
prettyDef (Decl _ pat _ def) =
   PP.pretty pat PP.<+>
   let (args, body) = dissectLambda def
   in (if not (null args)
          then PP.hsep (map PP.pretty args) PP.<> PP.space
          else PP.emptyDoc) PP.<>
      "=" PP.<+> PP.pretty body

prettyMaybeTypedArg :: (Name, Maybe Type) -> PP.Doc ann
prettyMaybeTypedArg (name,Nothing) =
   PP.pretty name
prettyMaybeTypedArg (name,Just typ) =
   PP.parens $ PP.pretty name PP.<+> PP.colon PP.<+> pretty 0 typ

dissectLambda :: Expr -> ([Pattern], Expr)
dissectLambda = \case
  Function _ pat (dissectLambda -> (pats, expr)) -> (pat : pats, expr)
  expr -> ([], expr)

pShow :: PrettyPrint a => a -> String
pShow = show . pretty 0

class PrettyPrint p where
  pretty :: Int -> p -> PP.Doc ann

instance PrettyPrint Schema where
  pretty _ (Forall ns t) = case ns of
    [] -> pretty 0 t
    _  -> PP.braces (commaSepAll $ map PP.pretty ns) PP.<+> pretty 0 t

instance PrettyPrint Type where
  pretty par t@(TyCon tc ts) = case (tc,ts) of
    (_,[])                 -> pretty par tc
    (TupleCon _,_)         -> PP.parens $ commaSepAll $ map (pretty 0) ts
    (ArrayCon,[typ])       -> PP.brackets (pretty 0 typ)
    (FunCon,[f,v])         -> (if par > 0 then PP.parens else id) $
                                pretty 1 f PP.<+> "->" PP.<+> pretty 0 v
    (BlockCon,[cxt,typ])   -> (if par > 1 then PP.parens else id) $
                                pretty 1 cxt PP.<+> pretty 2 typ
    _ -> error $ "malformed TyCon: " ++ show t
  pretty _par (TyRecord fs) =
      PP.braces
    $ commaSepAll
    $ map (\(n,t) -> PP.pretty n `prettyTypeSig` pretty 0 t)
    $ Map.toList fs
  pretty _par (TyUnifyVar i)    = "t." PP.<> PP.pretty i
  pretty _par (TySkolemVar n i) = PP.pretty n PP.<> PP.pretty i
  pretty _par (TyVar n)         = PP.pretty n
  pretty par (LType _ t)        = pretty par t

instance PrettyPrint TyCon where
  pretty par tc = case tc of
    TupleCon n     -> PP.parens $ replicateDoc (n - 1) $ PP.pretty ','
    ArrayCon       -> PP.parens $ PP.brackets $ PP.emptyDoc
    FunCon         -> PP.parens $ "->"
    StringCon      -> "String"
    TermCon        -> "Term"
    TypeCon        -> "Type"
    BoolCon        -> "Bool"
    IntCon         -> "Int"
    AIGCon         -> "AIG"
    CFGCon         -> "CFG"
    JVMSpecCon     -> "JVMSpec"
    LLVMSpecCon    -> "LLVMSpec"
    MIRSpecCon     -> "MIRSpec"
    BlockCon       -> "<Block>"
    ContextCon cxt -> pretty par cxt

instance PrettyPrint Context where
  pretty _ c = case c of
    CryptolSetup -> "CryptolSetup"
    JavaSetup    -> "JavaSetup"
    LLVMSetup    -> "LLVMSetup"
    MIRSetup     -> "MIRSetup"
    ProofScript  -> "ProofScript"
    TopLevel     -> "TopLevel"
    CrucibleSetup-> "CrucibleSetup"

replicateDoc :: Integer -> PP.Doc ann -> PP.Doc ann
replicateDoc n d
  | n < 1 = PP.emptyDoc
  | True  = d PP.<> replicateDoc (n-1) d

prettyTypeSig :: PP.Doc ann -> PP.Doc ann -> PP.Doc ann
prettyTypeSig n t = n PP.<+> PP.pretty ':' PP.<+> t

commaSep :: PP.Doc ann -> PP.Doc ann -> PP.Doc ann
commaSep = ((PP.<+>) . (PP.<> PP.comma))

commaSepAll :: [PP.Doc ann] -> PP.Doc ann
commaSepAll ds = case ds of
  [] -> PP.emptyDoc
  _  -> foldl1 commaSep ds

-- }}}

-- Type Constructors {{{

tMono :: Type -> Schema
tMono = Forall []

tForall :: [Name] -> Schema -> Schema
tForall xs (Forall ys t) = Forall (xs ++ ys) t

tTuple :: [Type] -> Type
tTuple ts = TyCon (TupleCon $ fromIntegral $ length ts) ts

tRecord :: [(Name, Type)] -> Type
tRecord fields = TyRecord (Map.fromList fields)

tArray :: Type -> Type
tArray t = TyCon ArrayCon [t]

tFun :: Type -> Type -> Type
tFun f v = TyCon FunCon [f,v]

tString :: Type
tString = TyCon StringCon []

tTerm :: Type
tTerm = TyCon TermCon []

tType :: Type
tType = TyCon TypeCon []

tBool :: Type
tBool = TyCon BoolCon []

tAIG :: Type
tAIG = TyCon AIGCon []

tCFG :: Type
tCFG = TyCon CFGCon []

tInt :: Type
tInt = TyCon IntCon []

tJVMSpec :: Type
tJVMSpec = TyCon JVMSpecCon []

tLLVMSpec :: Type
tLLVMSpec = TyCon LLVMSpecCon []

tMIRSpec :: Type
tMIRSpec = TyCon MIRSpecCon []

tBlock :: Type -> Type -> Type
tBlock c t = TyCon BlockCon [c,t]

tContext :: Context -> Type
tContext c = TyCon (ContextCon c) []

tVar :: Name -> Type
tVar n = TyVar n

-- }}}

-- Type Classifiers {{{

-- The idea is that calling these is/should be less messy than direct
-- pattern matching, and also help a little to avoid splattering the
-- internal representation of types all over the place.

-- | Check if type 'ty' is a 'Context' type of context 'c'.
isContext ::
       Context          -- ^ The context 'c' to look for
    -> Type             -- ^ The type 'ty' to inspect
    -> Bool
isContext c ty = case ty of
  TyCon (ContextCon c') [] | c' == c -> True
  _ -> False

-- }}}
