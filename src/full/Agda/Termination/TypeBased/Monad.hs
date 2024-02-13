module Agda.Termination.TypeBased.Monad where

import Control.Monad.Trans.State ( StateT, gets, modify, runStateT )
import Agda.TypeChecking.Monad.Base ( TCM, pattern Function, funTerminates, FunctionData (..), pattern Datatype, pattern Record, recInduction, Reduced (..), liftTCM, theDef, defType, defSizedType, defCopy, defIsDataOrRecord, MonadTCEnv, MonadTCState, HasOptions, Closure, MonadTCM, ReadTCState )
import Agda.TypeChecking.Monad.Debug ( MonadDebug, reportSDoc )
import Agda.TypeChecking.Monad.Signature ( getConstInfo, HasConstInfo, usesCopatterns )
import Agda.TypeChecking.Monad.Context ( MonadAddContext )
import qualified Data.Map as Map
import Data.Map ( Map)
import qualified Data.IntMap as IntMap
import Data.IntMap ( IntMap )
import qualified Data.IntSet as IntSet
import Data.IntSet ( IntSet )
import Control.Monad.IO.Class ( MonadIO )
import qualified Data.List as List
import Agda.Syntax.Abstract.Name ( QName )
import Agda.Termination.TypeBased.Syntax
import Agda.Syntax.Internal ( Term (..), unEl, unAbs, unDom, Dom, Abs(..), Sort, MetaId(..), isApplyElim )
import Agda.TypeChecking.Monad.Statistics ( MonadStatistics )
import Agda.Termination.TypeBased.Common

import Agda.TypeChecking.Pretty
import Control.Arrow ( first )
import Control.Monad
import Data.Maybe
import Data.Set (Set )

import Agda.Utils.Impossible

import qualified Agda.Utils.Benchmark as B
import qualified Agda.Benchmarking as Benchmark

import qualified Agda.Syntax.Common.Pretty as P

newtype MonadSizeChecker a = MSC (StateT SizeCheckerState TCM a)
  deriving (Functor, Applicative, Monad, MonadTCEnv, MonadTCState, HasOptions, MonadDebug, MonadFail, HasConstInfo, MonadAddContext, MonadIO, MonadTCM, ReadTCState, MonadStatistics)

instance B.MonadBench MonadSizeChecker where
  type BenchPhase MonadSizeChecker = Benchmark.Phase
  getBenchmark              = MSC $ B.getBenchmark
  putBenchmark              = MSC . B.putBenchmark
  modifyBenchmark           = MSC . B.modifyBenchmark
  finally (MSC m) (MSC f) = MSC $ (B.finally m f)

type SizeContextEntry = (Int, Either FreeGeneric SizeType)


data ConstrType = SLte | SLeq deriving (Eq, Ord)

instance P.Pretty ConstrType where
  pretty SLte = "<"
  pretty SLeq = "≤"

data SConstraint = SConstraint { scType :: ConstrType, scFrom :: Int, scTo :: Int }

data SizeCheckerState = SizeCheckerState
  { scsMutualNames            :: Set QName
  -- ^ Definitions that are in the current mutual block
  , scsCurrentFunc            :: QName
  -- ^ The function that is checked at the moment
  , scsRecCalls               :: [(QName, QName, [Int], [Int], Closure Term)]
  -- ^ [(f, g, Psi_f, Psi_g, place)], where Psi is the representation of the size context (see Abel & Pientka 2016)
  , scsConstraints            :: [SConstraint]
  -- ^ Lists of edges in the size dependency graph.
  --   This field is local to each clause.
  , scsTotalConstraints       :: [SConstraint]
  -- ^ The list of all constraints during function processing.
  --   This list is global across the function
  , scsRigidSizeVars          :: [(Int, SizeBound)]
  -- ^ Variables that are obtained during the process of pattern matching.
  --   All flexible variables should be expressed as infinity or a rigid variable in the end.
  --   Local to a clause.
  , scsCoreContext            :: [SizeContextEntry]
  -- ^ Size types of the variables from internal syntax.
  --   Local to a clause.
  , scsFreshVarCounter        :: Int
  -- ^ A counter that represents a pool of new first-order size variables. Both rigid and flexible variables are taken from this pool.
  , scsBottomFlexVars         :: IntSet
  -- ^ Flexible variabless that correspond to a non-recursive constructor
  --   The motivation here is that non-recursive constructors (i.e. `zero` of `Nat`) are not bigger than any other term of their type,
  --   so recursive calls with them do not induce undefined order.
  --   In our implementation, we instantiate bottom flexible variables to the minimum of all known leaf rigids.
  , scsLeafSizeVariables       :: [Int]
  -- ^ Rigid size variables that are located at the lowest level of their cluster.
  --   This field is used to assign meaningful sizes to non-recursive constructors,
  --   i.e. the minimum of `scsLeafSizeVariables` is the final expression for size variables variables in `scsBottomFlexVars`.
  --   Populated during the checking of pattern's LHS. The sizes of patterns that are the leaves of the rigid size tree
  , scsContravariantVariables :: IntSet
  -- ^ Size variables that belong to coinductive definitions.
  , scsFallbackInstantiations :: IntMap Int
  -- ^ Instantiations for a flexible variables, that are used only if it is impossible to know the instantiation otherwise from the graph.
  --   This is the last resort, and a desperate attempt to guess at least something more useful than infinity.
  --   Often this situation happens after projecting a record, where some size variables are simply gone for the later analysis.
  , scsUndefinedVariables     :: IntSet
  -- ^ A set of size variables that encountered an undefined size as their lower bound.
  --   These sizes are inherently unknown, and we can shortcut them during the processing of the graph.
  , scsRecCallsMatrix         :: [[Int]]
  -- ^ When a function calls itself, it becomes a subject of analysis for possible size preservation.
  --   Since we freshen the signatures of all functions that are used in the body,
  --   we can think of a "matrix" of size variables, where the rows correspond to the usages of the same function,
  --   and the columns are freshened versions of the same variable.
  --   During the size preservation, we merge two columns and look at the resulting graph.
  --   Example:
  --   If function `foo : t₀ -> t₁` calls itself, then the call has fresh signature `foo : t₂ -> t₃`, and `scsRecCallsMatrix == [[0, 1], [2, 3]]`
  , scsPreservationCandidates :: IntMap [Int]
  -- ^ A mapping from a variable that can reflect preservation to the possible candidates of preservation.
  --   For example, consider inductive size preservation.
  --   The algorithm of inference starts with each codomain variable being assigned to all domain variables (candidates),
  --   and then clause by clause these candidates are getting refined, i.e. the algorithm prunes the domain variables that certainly cannot appear in a codomain variable.
  , scsErrorMessages          :: [String]
  -- ^ Custom error messages during the process of checking. This is mostly TODO,
  --   because in the current implementation the failure of type-based termination hands the control to syntax-based checker, which will fail with its own errors.
  --   However we still might need to abort type-based termination sometimes,
  --   e.g. a postulated univalence axiom may break the type-based termination checker with an internal error.
  }

getCurrentConstraints :: MonadSizeChecker [SConstraint]
getCurrentConstraints = MSC $ gets scsConstraints

getTotalConstraints :: MonadSizeChecker [SConstraint]
getTotalConstraints = MSC $ gets scsTotalConstraints

getCurrentRigids :: MonadSizeChecker [(Int, SizeBound)]
getCurrentRigids = MSC $ gets scsRigidSizeVars

-- | Adds a new rigid variable. This function is fragile, since bound might not be expressed in terms of current rigids.
--   Unfortunately we have to live with it if we want to support record projections in arbitrary places.
addNewRigid :: Int -> SizeBound -> MonadSizeChecker ()
addNewRigid x bound = MSC $ modify \s -> s { scsRigidSizeVars = ((x, bound) : scsRigidSizeVars s) }

getCurrentCoreContext :: MonadSizeChecker [SizeContextEntry]
getCurrentCoreContext = MSC $ gets scsCoreContext

-- | Initializes internal data strustures that will be filled by the processing of a clause
initNewClause :: [SizeBound] -> MonadSizeChecker ()
initNewClause bounds = MSC $ modify (\s -> s
  { scsRigidSizeVars = (zip [0..length bounds] (replicate (length bounds) SizeUnbounded))
  , scsConstraints = [] -- a graph obtained by the processing of a clause corresponds to the clause's rigids
  , scsCoreContext = [] -- like in internal syntax, each clause lives in a separate context
  })

isContravariant :: Size -> MonadSizeChecker Bool
isContravariant SUndefined = pure False
isContravariant (SDefined i) = do
  IntSet.member i <$> MSC (gets scsContravariantVariables)

getContravariantSizeVariables :: MonadSizeChecker IntSet
getContravariantSizeVariables = MSC $ gets scsContravariantVariables

recordContravariantSizeVariable :: Int -> MonadSizeChecker ()
recordContravariantSizeVariable i = MSC $ modify (\s -> s { scsContravariantVariables = IntSet.insert i (scsContravariantVariables s) })

-- | Retrieves the number of size variables in the sized signature of @qn@
getArity :: QName -> MonadSizeChecker Int
getArity qn = sizeSigArity . fromJust . defSizedType <$> getConstInfo qn

storeConstraint :: SConstraint -> MonadSizeChecker ()
storeConstraint c = MSC $ modify \ s -> s
  { scsConstraints = c : (scsConstraints s)
  , scsTotalConstraints = c : scsTotalConstraints s
  }

reportCall :: QName -> QName -> [Int] -> [Int] -> Closure Term -> MonadSizeChecker ()
reportCall q1 q2 sizes1 sizes2 place = MSC $ modify (\s -> s { scsRecCalls = (q1, q2, sizes1, sizes2, place) : scsRecCalls s })

setLeafSizeVariables :: [Int] -> MonadSizeChecker ()
setLeafSizeVariables leaves = MSC $ modify (\s -> s { scsLeafSizeVariables = leaves })

currentCheckedName :: MonadSizeChecker QName
currentCheckedName = MSC $ gets scsCurrentFunc

getRootArity :: MonadSizeChecker Int
getRootArity = do
  rootName <- currentCheckedName
  getArity rootName

currentMutualNames :: MonadSizeChecker (Set QName)
currentMutualNames = MSC $ gets scsMutualNames

addFallbackInstantiation :: Int -> Int -> MonadSizeChecker ()
addFallbackInstantiation i j = MSC $ modify (\s -> s { scsFallbackInstantiations = IntMap.insert i j (scsFallbackInstantiations s) })

-- | Size-preservation machinery needs to know about recursive calls.
-- See the documentation for @scsRecCallsMatrix@
reportDirectRecursion :: [Int] -> MonadSizeChecker ()
reportDirectRecursion sizes = MSC $ modify (\s -> s { scsRecCallsMatrix = sizes : scsRecCallsMatrix s })

storeBottomVariable :: Int -> MonadSizeChecker ()
storeBottomVariable i = MSC $ modify (\s -> s { scsBottomFlexVars = IntSet.insert i (scsBottomFlexVars s)})

markUndefinedSize :: Int -> MonadSizeChecker ()
markUndefinedSize i = MSC $ modify (\s -> s { scsUndefinedVariables = IntSet.insert i (scsUndefinedVariables s)})

getUndefinedSizes :: MonadSizeChecker IntSet
getUndefinedSizes = MSC $ gets scsUndefinedVariables

abstractCoreContext :: Int -> Either FreeGeneric SizeType -> MonadSizeChecker a -> MonadSizeChecker a
abstractCoreContext i tele action = do
  contexts <- MSC $ gets scsCoreContext
  MSC $ modify \s -> s { scsCoreContext = ((i, tele) : map (incrementDeBruijnEntry tele) contexts) }
  res <- action
  MSC $ modify \s -> s { scsCoreContext = contexts }
  pure res

incrementDeBruijnEntry :: Either FreeGeneric SizeType -> (Int, Either FreeGeneric SizeType) -> (Int, Either FreeGeneric SizeType)
incrementDeBruijnEntry (Left _) (x, Left fg) = (x + 1, Left $ fg { fgIndex = fgIndex fg + 1 })
incrementDeBruijnEntry (Left _) (x, Right t) = (x + 1, Right t)
incrementDeBruijnEntry (Right _) (x, e) = (x + 1, e)

requestNewVariable :: MonadSizeChecker Int
requestNewVariable = MSC $ do
  x <- gets scsFreshVarCounter
  modify (\s -> s { scsFreshVarCounter = (x + 1) })
  return x

withAnotherPreservationCandidate :: Int -> MonadSizeChecker a -> MonadSizeChecker a
withAnotherPreservationCandidate candidate action = do
  oldState <- MSC $ gets scsPreservationCandidates
  MSC $ modify (\s -> s { scsPreservationCandidates = IntMap.insert candidate [] oldState })
  res <- action
  MSC $ modify (\s -> s { scsPreservationCandidates = oldState })
  pure res

instance Show SConstraint where
  show (SConstraint SLeq i1 i2) = show i1 ++ " ≤ " ++ show i2
  show (SConstraint SLte i1 i2) = show i1 ++ " < " ++ show i2

-- | Given the signature, returns it with with fresh variables
freshenSignature :: SizeSignature -> MonadSizeChecker ([SConstraint], SizeType)
freshenSignature s@(SizeSignature domain contra tele) = do
  -- reportSDoc "term.tbt" 10 $ "Signature to freshen: " <+> text (show s)
  newVars <- replicateM (length domain) requestNewVariable
  let actualConstraints = mapMaybe (\(v, d) -> case d of
                            SizeUnbounded -> Nothing
                            SizeBounded i -> Just (SConstraint SLte v (newVars List.!! i))) (zip newVars domain)
      sigWithfreshenedSizes = instantiateSizeType tele newVars
  -- freshSig <- freshenGenericArguments sigWithfreshenedSizes
  let newContravariantVariables = map (newVars List.!!) contra
  MSC $ modify ( \s -> s { scsContravariantVariables = foldr IntSet.insert (scsContravariantVariables s) newContravariantVariables  })
  return $ (actualConstraints, sigWithfreshenedSizes)

-- | Instantiates first order size variables to the provided list of ints
instantiateSizeType :: SizeType -> [Int] -> SizeType
instantiateSizeType body args = update (\i -> args List.!! i) body

requestNewRigidVariable :: SizeBound -> MonadSizeChecker Int
requestNewRigidVariable bound = do
  newVarIdx <- requestNewVariable
  MSC $ do
    currentRigids <- gets scsRigidSizeVars
    modify \s -> s { scsRigidSizeVars = ((newVarIdx, bound) : currentRigids) }
    return newVarIdx

appendCoreVariable :: Int -> Either FreeGeneric SizeType -> MonadSizeChecker ()
appendCoreVariable i tele = MSC $ modify \s -> s { scsCoreContext = ((i, tele) : (scsCoreContext s)) }

runSizeChecker :: QName -> Set QName -> MonadSizeChecker a -> TCM (a, SizeCheckerState)
runSizeChecker rootName mutualNames (MSC action) = do
  runStateT action
    (SizeCheckerState
    { scsMutualNames = mutualNames
    , scsCurrentFunc = rootName
    , scsRecCalls = []
    , scsConstraints = []
    , scsTotalConstraints = []
    , scsRigidSizeVars = []
    , scsFreshVarCounter = 0
    , scsCoreContext = []
    , scsBottomFlexVars = IntSet.empty
    , scsLeafSizeVariables = []
    , scsContravariantVariables = IntSet.empty
    , scsFallbackInstantiations = IntMap.empty
    , scsUndefinedVariables = IntSet.empty
    , scsRecCallsMatrix = []
    , scsPreservationCandidates = IntMap.empty
    , scsErrorMessages = []
    })