{-# LANGUAGE DeriveDataTypeable, FlexibleContexts #-}
module Transformation.Formulae where

import Data.Typeable
import Data.Data
import Data.SBV
import Data.Maybe
import Data.Foldable

import qualified Data.Map.Strict as Map
import qualified Data.Set.Monad as Set
import Data.Generics.Uniplate.Data

import Control.Monad
import Control.Monad.Except

import FPromela.Ast as FP
import TVL.Ast as T
import Abstraction.Ast(Lit(..))

data Formula = FVar String
             | FFalse
             | FTrue
             | (:!:) Formula
             | Formula :&: Formula
             | Formula :|: Formula
             | Formula :=>: Formula
     deriving (Eq, Show, Ord, Data, Typeable)


featureToPred :: SymWord a => String -> Map.Map String (SBV a) -> Symbolic (Map.Map String (SBV a))
featureToPred f m = do
      val <- exists f
      return $ Map.insert f val m

allSatisfiable :: (Monad m, MonadIO m) => Formula -> m [Map.Map String Bool]
allSatisfiable frm = do
  let features = [x | FVar x <- universe frm]
  let pred = do fs <- foldrM featureToPred Map.empty features
                Right v <- runExceptT (interpretAsSBool fs frm)
                return v
  satRes <- liftIO $ allSat pred
  return . map (Map.map cwToBool) $ getModelDictionaries satRes

nnf :: Formula -> Formula
nnf = rewrite nnf'
  where nnf' ((:!:) ((:!:) phi))   = Just phi
        nnf' ((:!:) (phi :&: psi)) = Just ((:!:) phi :|: (:!:) psi)
        nnf' ((:!:) (phi :|: psi)) = Just ((:!:) phi :&: (:!:) psi)
        nnf' (phi :=>: psi)        = Just ((:!:) phi :|: psi)
        nnf' _                     = Nothing

fAll :: [Formula] -> Formula
fAll []  = FTrue
fAll [f] = f
fAll (f:fs) =
  case (f, fAll fs) of
    (_, FTrue)  -> f
    (_, FFalse) -> FFalse
    (FTrue, f') -> f'
    (FFalse, _) -> FFalse
    (_, f')     -> f :&: f'

fAny :: [Formula] -> Formula
fAny []  = FFalse
fAny [f] = f
fAny (f:fs) =
  case (f, fAny fs) of
    (_, FTrue)   -> FTrue
    (_, FFalse)  -> f
    (FTrue, _)   -> FTrue
    (FFalse, f') -> f'
    (_, f')      -> f :|: f'

fromBool :: Bool -> Formula
fromBool True = FTrue
fromBool False = FFalse

fromFPromelaExpr :: (Monad m, MonadError String m) => String -> FP.Expr -> m Formula
fromFPromelaExpr prefix (FP.ELogic e1 "||" e2) = do
  phi1 <- fromFPromelaExpr prefix e1
  phi2 <- fromFPromelaExpr prefix e2
  return (phi1 :|: phi2)
fromFPromelaExpr prefix (FP.ELogic e1 "&&" e2) = do
  phi1 <- fromFPromelaExpr prefix e1
  phi2 <- fromFPromelaExpr prefix e2
  return (phi1 :&: phi2)
fromFPromelaExpr prefix (FP.EAnyExpr ae) = fromFPromelaAnyExpr ae
  where fromFPromelaAnyExpr (FP.AeVarRef (FP.VarRef prefix' Nothing (Just (FP.VarRef name Nothing Nothing))))
           | prefix' == prefix = return $ FVar name
        fromFPromelaAnyExpr (FP.AeConst FP.CstFalse) = return FFalse
        fromFPromelaAnyExpr (FP.AeConst FP.CstTrue)  = return FTrue
        fromFPromelaAnyExpr (FP.AeBinOp e1 "&&" e2) = do
          phi1 <- fromFPromelaAnyExpr e1
          phi2 <- fromFPromelaAnyExpr e2
          return (phi1 :&: phi2)
        fromFPromelaAnyExpr (FP.AeBinOp e1 "||" e2) = do
          phi1 <- fromFPromelaAnyExpr e1
          phi2 <- fromFPromelaAnyExpr e2
          return (phi1 :|: phi2)
        fromFPromelaAnyExpr (FP.AeUnOp "!" e1) = do
          phi1 <- fromFPromelaAnyExpr e1
          return $ (:!:) phi1
        fromFPromelaAnyExpr e = throwError ("Unsupported expression: " ++ show e)
fromFPromelaExpr prefix e               = throwError ("Unsupported expression: " ++ show e)

fromLits :: (Monad m, MonadError String m) => [Lit] -> m Formula
fromLits (x : xs) = return $ foldr (\l phi -> fromLit l :&: phi) (fromLit x) xs
  where fromLit (PosLit var) = FVar var
        fromLit (NegLit var) = (:!:) $ FVar var
fromLits [] = throwError "INTERNAL ERROR: Empty list unsupported by fromLits"

interpretAsFPromelaExpr :: String -> Formula -> FP.Expr
interpretAsFPromelaExpr prefix phi = FP.EAnyExpr $ interpretAsFPromelaAnyExpr prefix phi
  where interpretAsFPromelaAnyExpr :: String -> Formula -> FP.AnyExpr
        interpretAsFPromelaAnyExpr prefix (FVar name) =
                FP.AeVarRef $ FP.VarRef prefix Nothing (Just $ FP.VarRef name Nothing Nothing)
        interpretAsFPromelaAnyExpr prefix FFalse =
                FP.AeConst FP.CstFalse
        interpretAsFPromelaAnyExpr prefix FTrue =
                FP.AeConst FP.CstTrue
        interpretAsFPromelaAnyExpr prefix ((:!:) phi) =
           let phiExpr = interpretAsFPromelaAnyExpr prefix phi
           in FP.AeUnOp "!" phiExpr
        interpretAsFPromelaAnyExpr prefix (phi1 :&: phi2) =
           let phiExpr1 = interpretAsFPromelaAnyExpr prefix phi1
               phiExpr2 = interpretAsFPromelaAnyExpr prefix phi2
           in FP.AeBinOp phiExpr1 "&&" phiExpr2
        interpretAsFPromelaAnyExpr prefix (phi1 :|: phi2) =
           let phiExpr1 = interpretAsFPromelaAnyExpr prefix phi1
               phiExpr2 = interpretAsFPromelaAnyExpr prefix phi2
           in FP.AeBinOp phiExpr1 "||" phiExpr2
        interpretAsFPromelaAnyExpr prefix (phi1 :=>: phi2) =
           let phiExpr1 = interpretAsFPromelaAnyExpr prefix phi1
               phiExpr2 = interpretAsFPromelaAnyExpr prefix phi2
           in FP.AeBinOp (FP.AeUnOp "!" phiExpr1) "||" phiExpr2

interpretAsSBool :: (Monad m, MonadError String m) => Map.Map String SBool -> Formula -> m SBool
interpretAsSBool env (FVar name) =
  case Map.lookup name env of
    Nothing  -> throwError ("Unassigned variable " ++ show name)
    (Just p) -> return p
interpretAsSBool env FFalse      = return $ false
interpretAsSBool env FTrue       = return $ true
interpretAsSBool env ((:!:) phi) = do
  phip <- interpretAsSBool env phi
  return $ bnot phip
interpretAsSBool env (phi1 :&: phi2) = do
  phi1p <- interpretAsSBool env phi1
  phi2p <- interpretAsSBool env phi2
  return $ (phi1p &&& phi2p)
interpretAsSBool env (phi1 :|: phi2) = do
  phi1p <- interpretAsSBool env phi1
  phi2p <- interpretAsSBool env phi2
  return $ (phi1p ||| phi2p)
interpretAsSBool env (phi1 :=>: phi2) = do
  phi1p <- interpretAsSBool env phi1
  phi2p <- interpretAsSBool env phi2
  return $ (phi1p ==> phi2p)

interpretAsBool :: (Monad m, MonadError String m) => Map.Map String Bool -> Formula -> m Bool
interpretAsBool env (FVar name) =
  case Map.lookup name env of
    Nothing  -> throwError ("Unassigned variable " ++ show name)
    (Just p) -> return p
interpretAsBool env FFalse      = return false
interpretAsBool env FTrue       = return true
interpretAsBool env ((:!:) phi) = do
  phip <- interpretAsBool env phi
  return $ bnot phip
interpretAsBool env (phi1 :&: phi2) = do
  phi1p <- interpretAsBool env phi1
  phi2p <- interpretAsBool env phi2
  return (phi1p &&& phi2p)
interpretAsBool env (phi1 :|: phi2) = do
  phi1p <- interpretAsBool env phi1
  phi2p <- interpretAsBool env phi2
  return (phi1p ||| phi2p)
interpretAsBool env (phi1 :=>: phi2) = do
  phi1p <- interpretAsBool env phi1
  phi2p <- interpretAsBool env phi2
  return (phi1p ==> phi2p)

interpretAsTVLConstraint :: Formula -> T.ConstraintDecl
interpretAsTVLConstraint = CtExpr . interpretAsTVLExpr
  where interpretAsTVLExpr :: Formula -> T.Expr
        interpretAsTVLExpr (FVar name) = T.Ref name
        interpretAsTVLExpr FFalse      = T.EBool False
        interpretAsTVLExpr FTrue       = T.EBool True
        interpretAsTVLExpr ((:!:) phi) = T.UnOp "!" (interpretAsTVLExpr phi)
        interpretAsTVLExpr (phi1 :&: phi2)  = T.BinOp "&&" (interpretAsTVLExpr phi1) (interpretAsTVLExpr phi2)
        interpretAsTVLExpr (phi1 :|: phi2)  = T.BinOp "||" (interpretAsTVLExpr phi1) (interpretAsTVLExpr phi2)
        interpretAsTVLExpr (phi1 :=>: phi2) = interpretAsTVLExpr ((:!:) phi1 :|: phi2)

graft :: Map.Map String Formula -> Formula -> Formula
graft env (FVar name) =
  fromMaybe (FVar name) $ Map.lookup name env
graft env phi =
  descend (transform $ graft env) phi