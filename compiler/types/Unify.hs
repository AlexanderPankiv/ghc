-- (c) The University of Glasgow 2006

{-# LANGUAGE CPP, DeriveFunctor #-}

module Unify (
        -- Matching of types:
        --      the "tc" prefix indicates that matching always
        --      respects newtypes (rather than looking through them)
        tcMatchTy, tcUnifyTyWithTFs, tcMatchTys, tcMatchTyX, tcMatchTysX,
        ruleMatchTyX, tcMatchPreds,

        MatchEnv(..), matchList,

        typesCantMatch,

        -- Side-effect free unification
        tcUnifyTy, tcUnifyTys, BindFlag(..),

        UnifyResultM(..), UnifyResult, tcUnifyTysFG

   ) where

#include "HsVersions.h"

import Var
import VarEnv
import VarSet
import Kind
import Type
import TyCon
import TypeRep
import Util ( filterByList )
import Outputable
import FastString (sLit)

import Control.Monad (liftM, foldM, ap)
#if __GLASGOW_HASKELL__ < 709
import Control.Applicative (Applicative(..))
#endif

{-
************************************************************************
*                                                                      *
                Matching
*                                                                      *
************************************************************************


Matching is much tricker than you might think.

1. The substitution we generate binds the *template type variables*
   which are given to us explicitly.

2. We want to match in the presence of foralls;
        e.g     (forall a. t1) ~ (forall b. t2)

   That is what the RnEnv2 is for; it does the alpha-renaming
   that makes it as if a and b were the same variable.
   Initialising the RnEnv2, so that it can generate a fresh
   binder when necessary, entails knowing the free variables of
   both types.

3. We must be careful not to bind a template type variable to a
   locally bound variable.  E.g.
        (forall a. x) ~ (forall b. b)
   where x is the template type variable.  Then we do not want to
   bind x to a/b!  This is a kind of occurs check.
   The necessary locals accumulate in the RnEnv2.
-}

data MatchEnv
  = ME  { me_tmpls :: VarSet    -- Template variables
        , me_env   :: RnEnv2    -- Renaming envt for nested foralls
        }                       --   In-scope set includes template variables
    -- Nota Bene: MatchEnv isn't specific to Types.  It is used
    --            for matching terms and coercions as well as types

tcMatchTy :: TyVarSet           -- Template tyvars
          -> Type               -- Template
          -> Type               -- Target
          -> Maybe TvSubst      -- One-shot; in principle the template
                                -- variables could be free in the target
tcMatchTy tmpls ty1 ty2
  = tcMatchTyX tmpls init_subst ty1 ty2
  where
    init_subst = mkTvSubst in_scope emptyTvSubstEnv
    in_scope   = mkInScopeSet (tmpls `unionVarSet` tyVarsOfType ty2)
        -- We're assuming that all the interesting
        -- tyvars in ty1 are in tmpls

tcMatchTys :: TyVarSet          -- Template tyvars
           -> [Type]            -- Template
           -> [Type]            -- Target
           -> Maybe TvSubst     -- One-shot; in principle the template
                                -- variables could be free in the target
tcMatchTys tmpls tys1 tys2
  = tcMatchTysX tmpls init_subst tys1 tys2
  where
    init_subst = mkTvSubst in_scope emptyTvSubstEnv
    in_scope   = mkInScopeSet (tmpls `unionVarSet` tyVarsOfTypes tys2)

tcMatchTyX :: TyVarSet          -- Template tyvars
           -> TvSubst           -- Substitution to extend
           -> Type              -- Template
           -> Type              -- Target
           -> Maybe TvSubst
tcMatchTyX tmpls (TvSubst in_scope subst_env) ty1 ty2
  = case match menv subst_env ty1 ty2 of
        Just subst_env' -> Just (TvSubst in_scope subst_env')
        Nothing         -> Nothing
  where
    menv = ME {me_tmpls = tmpls, me_env = mkRnEnv2 in_scope}

tcMatchTysX :: TyVarSet          -- Template tyvars
            -> TvSubst           -- Substitution to extend
            -> [Type]            -- Template
            -> [Type]            -- Target
            -> Maybe TvSubst     -- One-shot; in principle the template
                                 -- variables could be free in the target
tcMatchTysX tmpls (TvSubst in_scope subst_env) tys1 tys2
  = case match_tys menv subst_env tys1 tys2 of
        Just subst_env' -> Just (TvSubst in_scope subst_env')
        Nothing         -> Nothing
  where
    menv = ME { me_tmpls = tmpls, me_env = mkRnEnv2 in_scope }

tcMatchPreds
        :: [TyVar]                      -- Bind these
        -> [PredType] -> [PredType]
        -> Maybe TvSubstEnv
tcMatchPreds tmpls ps1 ps2
  = matchList (match menv) emptyTvSubstEnv ps1 ps2
  where
    menv = ME { me_tmpls = mkVarSet tmpls, me_env = mkRnEnv2 in_scope_tyvars }
    in_scope_tyvars = mkInScopeSet (tyVarsOfTypes ps1 `unionVarSet` tyVarsOfTypes ps2)

-- This one is called from the expression matcher, which already has a MatchEnv in hand
ruleMatchTyX :: MatchEnv
         -> TvSubstEnv          -- Substitution to extend
         -> Type                -- Template
         -> Type                -- Target
         -> Maybe TvSubstEnv

ruleMatchTyX menv subst ty1 ty2 = match menv subst ty1 ty2      -- Rename for export

-- Now the internals of matching

-- | Workhorse matching function.  Our goal is to find a substitution
-- on all of the template variables (specified by @me_tmpls menv@) such
-- that @ty1@ and @ty2@ unify.  This substitution is accumulated in @subst@.
-- If a variable is not a template variable, we don't attempt to find a
-- substitution for it; it must match exactly on both sides.  Furthermore,
-- only @ty1@ can have template variables.
--
-- This function handles binders, see 'RnEnv2' for more details on
-- how that works.
match :: MatchEnv       -- For the most part this is pushed downwards
      -> TvSubstEnv     -- Substitution so far:
                        --   Domain is subset of template tyvars
                        --   Free vars of range is subset of
                        --      in-scope set of the RnEnv2
      -> Type -> Type   -- Template and target respectively
      -> Maybe TvSubstEnv

match menv subst ty1 ty2 | Just ty1' <- coreView ty1 = match menv subst ty1' ty2
                         | Just ty2' <- coreView ty2 = match menv subst ty1 ty2'

match menv subst (TyVarTy tv1) ty2
  | Just ty1' <- lookupVarEnv subst tv1'        -- tv1' is already bound
  = if eqTypeX (nukeRnEnvL rn_env) ty1' ty2
        -- ty1 has no locally-bound variables, hence nukeRnEnvL
    then Just subst
    else Nothing        -- ty2 doesn't match

  | tv1' `elemVarSet` me_tmpls menv
  = if any (inRnEnvR rn_env) (varSetElems (tyVarsOfType ty2))
    then Nothing        -- Occurs check
                        -- ezyang: Is this really an occurs check?  It seems
                        -- to just reject matching \x. A against \x. x (maintaining
                        -- the invariant that the free vars of the range of @subst@
                        -- are a subset of the in-scope set in @me_env menv@.)
    else do { subst1 <- match_kind menv subst (tyVarKind tv1) (typeKind ty2)
                        -- Note [Matching kinds]
            ; return (extendVarEnv subst1 tv1' ty2) }

   | otherwise  -- tv1 is not a template tyvar
   = case ty2 of
        TyVarTy tv2 | tv1' == rnOccR rn_env tv2 -> Just subst
        _                                       -> Nothing
  where
    rn_env = me_env menv
    tv1' = rnOccL rn_env tv1

match menv subst (ForAllTy tv1 ty1) (ForAllTy tv2 ty2)
  = do { subst' <- match_kind menv subst (tyVarKind tv1) (tyVarKind tv2)
       ; match menv' subst' ty1 ty2 }
  where         -- Use the magic of rnBndr2 to go under the binders
    menv' = menv { me_env = rnBndr2 (me_env menv) tv1 tv2 }

match menv subst (TyConApp tc1 tys1) (TyConApp tc2 tys2)
  | tc1 == tc2 = match_tys menv subst tys1 tys2
match menv subst (FunTy ty1a ty1b) (FunTy ty2a ty2b)
  = do { subst' <- match menv subst ty1a ty2a
       ; match menv subst' ty1b ty2b }
match menv subst (AppTy ty1a ty1b) ty2
  | Just (ty2a, ty2b) <- repSplitAppTy_maybe ty2
        -- 'repSplit' used because the tcView stuff is done above
  = do { subst' <- match menv subst ty1a ty2a
       ; match menv subst' ty1b ty2b }

match _ subst (LitTy x) (LitTy y) | x == y  = return subst

match _ _ _ _
  = Nothing



--------------
match_kind :: MatchEnv -> TvSubstEnv -> Kind -> Kind -> Maybe TvSubstEnv
-- Match the kind of the template tyvar with the kind of Type
-- Note [Matching kinds]
match_kind menv subst k1 k2
  | k2 `isSubKind` k1
  = return subst

  | otherwise
  = match menv subst k1 k2

-- Note [Matching kinds]
-- ~~~~~~~~~~~~~~~~~~~~~
-- For ordinary type variables, we don't want (m a) to match (n b)
-- if say (a::*) and (b::*->*).  This is just a yes/no issue.
--
-- For coercion kinds matters are more complicated.  If we have a
-- coercion template variable co::a~[b], where a,b are presumably also
-- template type variables, then we must match co's kind against the
-- kind of the actual argument, so as to give bindings to a,b.
--
-- In fact I have no example in mind that *requires* this kind-matching
-- to instantiate template type variables, but it seems like the right
-- thing to do.  C.f. Note [Matching variable types] in Rules.hs

--------------
match_tys :: MatchEnv -> TvSubstEnv -> [Type] -> [Type] -> Maybe TvSubstEnv
match_tys menv subst tys1 tys2 = matchList (match menv) subst tys1 tys2

--------------
matchList :: (env -> a -> b -> Maybe env)
           -> env -> [a] -> [b] -> Maybe env
matchList _  subst []     []     = Just subst
matchList fn subst (a:as) (b:bs) = do { subst' <- fn subst a b
                                      ; matchList fn subst' as bs }
matchList _  _     _      _      = Nothing

{-
************************************************************************
*                                                                      *
                GADTs
*                                                                      *
************************************************************************

Note [Pruning dead case alternatives]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Consider        data T a where
                   T1 :: T Int
                   T2 :: T a

                newtype X = MkX Int
                newtype Y = MkY Char

                type family F a
                type instance F Bool = Int

Now consider    case x of { T1 -> e1; T2 -> e2 }

The question before the house is this: if I know something about the type
of x, can I prune away the T1 alternative?

Suppose x::T Char.  It's impossible to construct a (T Char) using T1,
        Answer = YES we can prune the T1 branch (clearly)

Suppose x::T (F a), where 'a' is in scope.  Then 'a' might be instantiated
to 'Bool', in which case x::T Int, so
        ANSWER = NO (clearly)

We see here that we want precisely the apartness check implemented within
tcUnifyTysFG. So that's what we do! Two types cannot match if they are surely
apart. Note that since we are simply dropping dead code, a conservative test
suffices.
-}

-- | Given a list of pairs of types, are any two members of a pair surely
-- apart, even after arbitrary type function evaluation and substitution?
typesCantMatch :: [(Type,Type)] -> Bool
-- See Note [Pruning dead case alternatives]
typesCantMatch prs = any (\(s,t) -> cant_match s t) prs
  where
    cant_match :: Type -> Type -> Bool
    cant_match t1 t2 = case tcUnifyTysFG (const BindMe) [t1] [t2] of
      SurelyApart -> True
      _           -> False

{-
************************************************************************
*                                                                      *
             Unification
*                                                                      *
************************************************************************

Note [Fine-grained unification]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Do the types (x, x) and ([y], y) unify? The answer is seemingly "no" --
no substitution to finite types makes these match. But, a substitution to
*infinite* types can unify these two types: [x |-> [[[...]]], y |-> [[[...]]] ].
Why do we care? Consider these two type family instances:

type instance F x x   = Int
type instance F [y] y = Bool

If we also have

type instance Looper = [Looper]

then the instances potentially overlap. The solution is to use unification
over infinite terms. This is possible (see [1] for lots of gory details), but
a full algorithm is a little more power than we need. Instead, we make a
conservative approximation and just omit the occurs check.

[1]: http://research.microsoft.com/en-us/um/people/simonpj/papers/ext-f/axioms-extended.pdf

tcUnifyTys considers an occurs-check problem as the same as general unification
failure.

tcUnifyTysFG ("fine-grained") returns one of three results: success, occurs-check
failure ("MaybeApart"), or general failure ("SurelyApart").

See also Trac #8162.

It's worth noting that unification in the presence of infinite types is not
complete. This means that, sometimes, a closed type family does not reduce
when it should. See test case indexed-types/should_fail/Overlap15 for an
example.

Note [The substitution in MaybeApart]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The constructor MaybeApart carries data with it, typically a TvSubstEnv. Why?
Because consider unifying these:

(a, a, Int) ~ (b, [b], Bool)

If we go left-to-right, we start with [a |-> b]. Then, on the middle terms, we
apply the subst we have so far and discover that we need [b |-> [b]]. Because
this fails the occurs check, we say that the types are MaybeApart (see above
Note [Fine-grained unification]). But, we can't stop there! Because if we
continue, we discover that Int is SurelyApart from Bool, and therefore the
types are apart. This has practical consequences for the ability for closed
type family applications to reduce. See test case
indexed-types/should_compile/Overlap14.

Note [Unifying with skolems]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
If we discover that two types unify if and only if a skolem variable is
substituted, we can't properly unify the types. But, that skolem variable
may later be instantiated with a unifyable type. So, we return maybeApart
in these cases.

Note [Lists of different lengths are MaybeApart]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
It is unusual to call tcUnifyTys or tcUnifyTysFG with lists of different
lengths. The place where we know this can happen is from compatibleBranches in
FamInstEnv, when checking data family instances. Data family instances may be
eta-reduced; see Note [Eta reduction for data family axioms] in TcInstDcls.

We wish to say that

  D :: * -> * -> *
  axDF1 :: D Int ~ DFInst1
  axDF2 :: D Int Bool ~ DFInst2

overlap. If we conclude that lists of different lengths are SurelyApart, then
it will look like these do *not* overlap, causing disaster. See Trac #9371.

In usages of tcUnifyTys outside of family instances, we always use tcUnifyTys,
which can't tell the difference between MaybeApart and SurelyApart, so those
usages won't notice this design choice.
-}

tcUnifyTy :: Type -> Type       -- All tyvars are bindable
          -> Maybe TvSubst      -- A regular one-shot (idempotent) substitution
-- Simple unification of two types; all type variables are bindable
tcUnifyTy ty1 ty2
  = case initUM (const BindMe) (unify ty1 ty2) of
      Unifiable subst -> Just subst
      _other          -> Nothing

-- | Unify two types, treating type family applications as possibly unifying
-- with anything and looking through injective type family applications.
tcUnifyTyWithTFs :: Bool -> Type -> Type -> Maybe TvSubst
-- This algorithm is a direct implementation of the "Algorithm U" presented in
-- the paper "Injective type families for Haskell", Figures 2 and 3.  Equation
-- numbers in the comments refer to equations from the paper.
tcUnifyTyWithTFs twoWay t1 t2 = niFixTvSubst `fmap` go t1 t2 emptyTvSubstEnv
    where
      go :: Type -> Type -> TvSubstEnv -> Maybe TvSubstEnv
      -- look through type synonyms
      go t1 t2 theta | Just t1' <- tcView t1 = go t1' t2  theta
      go t1 t2 theta | Just t2' <- tcView t2 = go t1  t2' theta
      -- proper unification
      go (TyVarTy tv) t2 theta
          -- Equation (1)
          | Just t1' <- lookupVarEnv theta tv
          = go t1' t2 theta
          | otherwise = let t2' = Type.substTy (niFixTvSubst theta) t2
                        in if tv `elemVarEnv` tyVarsOfType t2'
                           -- Equation (2)
                           then Just theta
                           -- Equation (3)
                           else Just $ extendVarEnv theta tv t2'
      -- Equation (4)
      go t1 t2@(TyVarTy _) theta | twoWay = go t2 t1 theta
      -- Equation (5)
      go (AppTy s1 s2) ty theta | Just(t1, t2) <- splitAppTy_maybe ty =
          go s1 t1 theta >>= go s2 t2
      go ty (AppTy s1 s2) theta | Just(t1, t2) <- splitAppTy_maybe ty =
          go s1 t1 theta >>= go s2 t2

      go (TyConApp tc1 tys1) (TyConApp tc2 tys2) theta
        -- Equation (6)
        | isAlgTyCon tc1 && isAlgTyCon tc2 && tc1 == tc2
        = let tys = zip tys1 tys2
          in foldM (\theta' (t1,t2) -> go t1 t2 theta') theta tys

        -- Equation (7)
        | isTypeFamilyTyCon tc1 && isTypeFamilyTyCon tc2 && tc1 == tc2
        , Injective inj <- familyTyConInjectivityInfo tc1
        = let tys1' = filterByList inj tys1
              tys2' = filterByList inj tys2
              injTys = zip tys1' tys2'
          in foldM (\theta' (t1,t2) -> go t1 t2 theta') theta injTys

        -- Equations (8)
        | isTypeFamilyTyCon tc1
        = Just theta

        -- Equations (9)
        | isTypeFamilyTyCon tc2, twoWay
        = Just theta

      -- Equation (10)
      go _ _ _ = Nothing

-----------------
tcUnifyTys :: (TyVar -> BindFlag)
           -> [Type] -> [Type]
           -> Maybe TvSubst     -- A regular one-shot (idempotent) substitution
-- The two types may have common type variables, and indeed do so in the
-- second call to tcUnifyTys in FunDeps.checkClsFD
tcUnifyTys bind_fn tys1 tys2
  = case tcUnifyTysFG bind_fn tys1 tys2 of
      Unifiable subst -> Just subst
      _               -> Nothing

-- This type does double-duty. It is used in the UM (unifier monad) and to
-- return the final result. See Note [Fine-grained unification]
type UnifyResult = UnifyResultM TvSubst
data UnifyResultM a = Unifiable a        -- the subst that unifies the types
                    | MaybeApart a       -- the subst has as much as we know
                                         -- it must be part of an most general unifier
                                         -- See Note [The substitution in MaybeApart]
                    | SurelyApart
                    deriving Functor

-- See Note [Fine-grained unification]
tcUnifyTysFG :: (TyVar -> BindFlag)
             -> [Type] -> [Type]
             -> UnifyResult
tcUnifyTysFG bind_fn tys1 tys2
  = initUM bind_fn (unify_tys tys1 tys2)

instance Outputable a => Outputable (UnifyResultM a) where
  ppr SurelyApart    = ptext (sLit "SurelyApart")
  ppr (Unifiable x)  = ptext (sLit "Unifiable") <+> ppr x
  ppr (MaybeApart x) = ptext (sLit "MaybeApart") <+> ppr x

{-
************************************************************************
*                                                                      *
                Non-idempotent substitution
*                                                                      *
************************************************************************

Note [Non-idempotent substitution]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
During unification we use a TvSubstEnv that is
  (a) non-idempotent
  (b) loop-free; ie repeatedly applying it yields a fixed point

Note [Finding the substitution fixpoint]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Finding the fixpoint of a non-idempotent substitution arising from a
unification is harder than it looks, because of kinds.  Consider
   T k (H k (f:k)) ~ T * (g:*)
If we unify, we get the substitution
   [ k -> *
   , g -> H k (f:k) ]
To make it idempotent we don't want to get just
   [ k -> *
   , g -> H * (f:k) ]
We also want to substitute inside f's kind, to get
   [ k -> *
   , g -> H k (f:*) ]
If we don't do this, we may apply the substitition to something,
and get an ill-formed type, i.e. one where typeKind will fail.
This happened, for example, in Trac #9106.

This is the reason for extending env with [f:k -> f:*], in the
definition of env' in niFixTvSubst
-}

niFixTvSubst :: TvSubstEnv -> TvSubst
-- Find the idempotent fixed point of the non-idempotent substitution
-- See Note [Finding the substitution fixpoint]
-- ToDo: use laziness instead of iteration?
niFixTvSubst env = f env
  where
    f env | not_fixpoint = f (mapVarEnv (substTy subst') env)
          | otherwise    = subst
        where
          not_fixpoint  = foldVarSet ((||) . in_domain) False all_range_tvs
          in_domain tv  = tv `elemVarEnv` env

          range_tvs     = foldVarEnv (unionVarSet . tyVarsOfType) emptyVarSet env
          all_range_tvs = closeOverKinds range_tvs
          subst         = mkTvSubst (mkInScopeSet all_range_tvs) env

             -- env' extends env by replacing any free type with
             -- that same tyvar with a substituted kind
             -- See note [Finding the substitution fixpoint]
          env'          = extendVarEnvList env [ (rtv, mkTyVarTy $ setTyVarKind rtv $
                                                       substTy subst $ tyVarKind rtv)
                                               | rtv <- varSetElems range_tvs
                                               , not (in_domain rtv) ]
          subst'        = mkTvSubst (mkInScopeSet all_range_tvs) env'

niSubstTvSet :: TvSubstEnv -> TyVarSet -> TyVarSet
-- Apply the non-idempotent substitution to a set of type variables,
-- remembering that the substitution isn't necessarily idempotent
-- This is used in the occurs check, before extending the substitution
niSubstTvSet subst tvs
  = foldVarSet (unionVarSet . get) emptyVarSet tvs
  where
    get tv = case lookupVarEnv subst tv of
               Nothing -> unitVarSet tv
               Just ty -> niSubstTvSet subst (tyVarsOfType ty)

{-
************************************************************************
*                                                                      *
                The workhorse
*                                                                      *
************************************************************************
-}

unify :: Type -> Type -> UM ()
-- Respects newtypes, PredTypes

-- in unify, any NewTcApps/Preds should be taken at face value
unify (TyVarTy tv1) ty2  = uVar tv1 ty2
unify ty1 (TyVarTy tv2)  = uVar tv2 ty1

unify ty1 ty2 | Just ty1' <- tcView ty1 = unify ty1' ty2
unify ty1 ty2 | Just ty2' <- tcView ty2 = unify ty1 ty2'

unify ty1 ty2
  | Just (tc1, tys1) <- splitTyConApp_maybe ty1
  , Just (tc2, tys2) <- splitTyConApp_maybe ty2
  = if tc1 == tc2
    then if isInjectiveTyCon tc1 Nominal
         then unify_tys tys1 tys2
         else don'tBeSoSure $ unify_tys tys1 tys2
    else -- tc1 /= tc2
         if isGenerativeTyCon tc1 Nominal && isGenerativeTyCon tc2 Nominal
         then surelyApart
         else maybeApart

        -- Applications need a bit of care!
        -- They can match FunTy and TyConApp, so use splitAppTy_maybe
        -- NB: we've already dealt with type variables and Notes,
        -- so if one type is an App the other one jolly well better be too
unify (AppTy ty1a ty1b) ty2
  | Just (ty2a, ty2b) <- repSplitAppTy_maybe ty2
  = do  { unify ty1a ty2a
        ; unify ty1b ty2b }

unify ty1 (AppTy ty2a ty2b)
  | Just (ty1a, ty1b) <- repSplitAppTy_maybe ty1
  = do  { unify ty1a ty2a
        ; unify ty1b ty2b }

unify (LitTy x) (LitTy y) | x == y = return ()

unify _ _ = surelyApart
        -- ForAlls??

------------------------------
unify_tys :: [Type] -> [Type] -> UM ()
unify_tys orig_xs orig_ys
  = go orig_xs orig_ys
  where
    go []     []     = return ()
    go (x:xs) (y:ys) = do { unify x y
                          ; go xs ys }
    go _ _ = maybeApart  -- See Note [Lists of different lengths are MaybeApart]

---------------------------------
uVar :: TyVar           -- Type variable to be unified
     -> Type            -- with this type
     -> UM ()

uVar tv1 ty
 = do { subst <- umGetTvSubstEnv
         -- Check to see whether tv1 is refined by the substitution
      ; case (lookupVarEnv subst tv1) of
          Just ty' -> unify ty' ty     -- Yes, call back into unify'
          Nothing  -> uUnrefined subst tv1 ty ty }  -- No, continue

uUnrefined :: TvSubstEnv          -- environment to extend (from the UM monad)
           -> TyVar               -- Type variable to be unified
           -> Type                -- with this type
           -> Type                -- (version w/ expanded synonyms)
           -> UM ()

-- We know that tv1 isn't refined

uUnrefined subst tv1 ty2 ty2'
  | Just ty2'' <- tcView ty2'
  = uUnrefined subst tv1 ty2 ty2''      -- Unwrap synonyms
                -- This is essential, in case we have
                --      type Foo a = a
                -- and then unify a ~ Foo a

uUnrefined subst tv1 ty2 (TyVarTy tv2)
  | tv1 == tv2          -- Same type variable
  = return ()

    -- Check to see whether tv2 is refined
  | Just ty' <- lookupVarEnv subst tv2
  = uUnrefined subst tv1 ty' ty'

  | otherwise

  = do {   -- So both are unrefined; unify the kinds
       ; unify (tyVarKind tv1) (tyVarKind tv2)

           -- And then bind one or the other,
           -- depending on which is bindable
           -- NB: unlike TcUnify we do not have an elaborate sub-kinding
           --     story.  That is relevant only during type inference, and
           --     (I very much hope) is not relevant here.
       ; b1 <- tvBindFlag tv1
       ; b2 <- tvBindFlag tv2
       ; let ty1 = TyVarTy tv1
       ; case (b1, b2) of
           (Skolem, Skolem) -> maybeApart -- See Note [Unification with skolems]
           (BindMe, _)      -> extendSubst tv1 ty2
           (_, BindMe)      -> extendSubst tv2 ty1 }

uUnrefined subst tv1 ty2 ty2'   -- ty2 is not a type variable
  | tv1 `elemVarSet` niSubstTvSet subst (tyVarsOfType ty2')
  = maybeApart                          -- Occurs check
                                        -- See Note [Fine-grained unification]
  | otherwise
  = do { unify k1 k2
       -- Note [Kinds Containing Only Literals]
       ; bindTv tv1 ty2 }        -- Bind tyvar to the synonym if poss
  where
    k1 = tyVarKind tv1
    k2 = typeKind ty2'

bindTv :: TyVar -> Type -> UM ()
bindTv tv ty      -- ty is not a type variable
  = do  { b <- tvBindFlag tv
        ; case b of
            Skolem -> maybeApart  -- See Note [Unification with skolems]
            BindMe -> extendSubst tv ty
        }

{-
************************************************************************
*                                                                      *
                Binding decisions
*                                                                      *
************************************************************************
-}

data BindFlag
  = BindMe      -- A regular type variable

  | Skolem      -- This type variable is a skolem constant
                -- Don't bind it; it only matches itself

{-
************************************************************************
*                                                                      *
                Unification monad
*                                                                      *
************************************************************************
-}

newtype UM a = UM { unUM :: (TyVar -> BindFlag)
                         -> TvSubstEnv
                         -> UnifyResultM (a, TvSubstEnv) }

instance Functor UM where
      fmap = liftM

instance Applicative UM where
      pure a = UM (\_tvs subst  -> Unifiable (a, subst))
      (<*>) = ap

instance Monad UM where
  return   = pure
  fail _   = UM (\_tvs _subst -> SurelyApart) -- failed pattern match
  m >>= k  = UM (\tvs  subst  -> case unUM m tvs subst of
                           Unifiable (v, subst') -> unUM (k v) tvs subst'
                           MaybeApart (v, subst') ->
                             case unUM (k v) tvs subst' of
                               Unifiable (v', subst'') -> MaybeApart (v', subst'')
                               other                   -> other
                           SurelyApart -> SurelyApart)

-- returns an idempotent substitution
initUM :: (TyVar -> BindFlag) -> UM () -> UnifyResult
initUM badtvs um = fmap (niFixTvSubst . snd) $ unUM um badtvs emptyTvSubstEnv

tvBindFlag :: TyVar -> UM BindFlag
tvBindFlag tv = UM (\tv_fn subst -> Unifiable (tv_fn tv, subst))

-- | Extend the TvSubstEnv in the UM monad
extendSubst :: TyVar -> Type -> UM ()
extendSubst tv ty = UM (\_tv_fn subst -> Unifiable ((), extendVarEnv subst tv ty))

-- | Retrive the TvSubstEnv from the UM monad
umGetTvSubstEnv :: UM TvSubstEnv
umGetTvSubstEnv = UM $ \_tv_fn subst -> Unifiable (subst, subst)

-- | Converts any SurelyApart to a MaybeApart
don'tBeSoSure :: UM () -> UM ()
don'tBeSoSure um = UM $ \tv_fn subst -> case unUM um tv_fn subst of
  SurelyApart -> MaybeApart ((), subst)
  other       -> other

maybeApart :: UM ()
maybeApart = UM (\_tv_fn subst -> MaybeApart ((), subst))

surelyApart :: UM a
surelyApart = UM (\_tv_fn _subst -> SurelyApart)
