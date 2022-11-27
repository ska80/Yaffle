module Core.Evaluate.Quote

-- Quoting evaluated values back to Terms

import Core.Context
import Core.Env
import Core.Error
import Core.TT
import Core.Evaluate.Value

import Data.Vect

data QVar : Type where

genName : Ref QVar Int => String -> Core Name
genName n
    = do i <- get QVar
         put QVar (i + 1)
         pure (MN n i)

data Strategy
  = NF (Maybe (List Namespace)) -- full normal form. If a namespace list is
                                -- given, these are the ones where we can
                                -- reduce 'export' names
  | HNF (Maybe (List Namespace)) -- head normal form (block under constructors)
  | Binders -- block after going under all the binders
  | BlockApp -- block all applications
  | ExpandHoles -- block all applications except holes

getNS : Strategy -> Maybe (List Namespace)
getNS (NF ns) = ns
getNS (HNF ns) = ns
getNS _ = Nothing

{-
On Strategy: when quoting to full NF, we still want to block the body of an
application if it turns out to be a case expression or primitive. This is
primarily for readability of the result because we want to see the function
that was blocked, not its complete definition.
-}

applySpine : Term vars -> SnocList (FC, RigCount, Term vars) -> Term vars
applySpine tm [<] = tm
applySpine tm (args :< (fc, q, arg)) = App fc (applySpine tm args) q arg

parameters {auto c : Ref Ctxt Defs} {auto q : Ref QVar Int}

  quoteGen : {bound, vars : _} ->
             Strategy -> Bounds bound -> Env Term vars ->
             Value f vars -> Core (Term (vars ++ bound))

  -- probably ought to make traverse work on SnocList/Vect too
  quoteSpine : {bound, vars : _} ->
               Strategy -> Bounds bound -> Env Term vars ->
               Spine vars -> Core (SnocList (FC, RigCount, Term (vars ++ bound)))
  quoteSpine s bounds env [<] = pure [<]
  quoteSpine s bounds env (args :< (fc, q, arg))
      = pure $ !(quoteSpine s bounds env args) :<
               (fc, q, !(quoteGen s bounds env arg))

  mkTmpVar : FC -> Name -> Glued vars
  mkTmpVar fc n = VApp fc Bound n [<] (pure Nothing)

  quoteAlt : {bound, vars : _} ->
             Strategy -> Bounds bound -> Env Term vars ->
             VCaseAlt vars -> Core (CaseAlt (vars ++ bound))
  quoteAlt {vars} s bounds env (VConCase fc n t a sc)
      = do sc' <- quoteScope a bounds sc
           pure $ ConCase fc n t sc'
    where
      quoteScope : {bound : _} ->
                   (args : SnocList (RigCount, Name)) ->
                   Bounds bound ->
                   VCaseScope args vars ->
                   Core (CaseScope (vars ++ bound))
      quoteScope [<] bounds rhs
          = do rhs' <- quoteGen s bounds env !rhs
               pure (RHS rhs')
      quoteScope (as :< (r, a)) bounds sc
          = do an <- genName "c"
               let sc' = sc (mkTmpVar fc an)
               rhs' <- quoteScope as (Add a an bounds) sc'
               pure (Arg r a rhs')

  quoteAlt s bounds env (VDelayCase fc ty arg sc)
      = do tyn <- genName "ty"
           argn <- genName "arg"
           sc' <- quoteGen s (Add ty tyn (Add arg argn bounds)) env
                           !(sc (mkTmpVar fc tyn) (mkTmpVar fc argn))
           pure (DelayCase fc ty arg sc')
  quoteAlt s bounds env (VConstCase fc c sc)
      = do sc' <- quoteGen s bounds env sc
           pure (ConstCase fc c sc')
  quoteAlt s bounds env (VDefaultCase fc sc)
      = do sc' <- quoteGen s bounds env sc
           pure (DefaultCase fc sc')

  quotePi : {bound, vars : _} ->
            Strategy -> Bounds bound -> Env Term vars ->
            PiInfo (Glued vars) -> Core (PiInfo (Term (vars ++ bound)))
  quotePi s bounds env Explicit = pure Explicit
  quotePi s bounds env Implicit = pure Implicit
  quotePi s bounds env AutoImplicit = pure AutoImplicit
  quotePi s bounds env (DefImplicit t)
      = do t' <- quoteGen s bounds env t
           pure (DefImplicit t')

  quoteBinder : {bound, vars : _} ->
                Strategy -> Bounds bound -> Env Term vars ->
                Binder (Glued vars) -> Core (Binder (Term (vars ++ bound)))
  quoteBinder s bounds env (Lam fc r p ty)
      = do ty' <- quoteGen s bounds env ty
           p' <- quotePi s bounds env p
           pure (Lam fc r p' ty')
  quoteBinder s bounds env (Let fc r val ty)
      = do ty' <- quoteGen s bounds env ty
           val' <- quoteGen s bounds env val
           pure (Let fc r val' ty')
  quoteBinder s bounds env (Pi fc r p ty)
      = do ty' <- quoteGen s bounds env ty
           p' <- quotePi s bounds env p
           pure (Pi fc r p' ty')
  quoteBinder s bounds env (PVar fc r p ty)
      = do ty' <- quoteGen s bounds env ty
           p' <- quotePi s bounds env p
           pure (PVar fc r p' ty')
  quoteBinder s bounds env (PLet fc r val ty)
      = do ty' <- quoteGen s bounds env ty
           val' <- quoteGen s bounds env val
           pure (PLet fc r val' ty')
  quoteBinder s bounds env (PVTy fc r ty)
      = do ty' <- quoteGen s bounds env ty
           pure (PVTy fc r ty')

--   Declared above as:
--   quoteGen : {bound, vars : _} ->
--              Strategy -> Bounds bound -> Env Term vars ->
--              Value f vars -> Core (Term (vars ++ bound))
  quoteGen s bounds env (VLam fc x c p ty sc)
      = do var <- genName "qv"
           p' <- quotePi s bounds env p
           ty' <- quoteGen s bounds env ty
           sc' <- quoteGen s (Add x var bounds) env
                             !(sc (mkTmpVar fc var))
           pure (Bind fc x (Lam fc c p' ty') sc')
  quoteGen s bounds env (VBind fc x b sc)
      = do var <- genName "qv"
           b' <- quoteBinder s bounds env b
           sc' <- quoteGen s (Add x var bounds) env
                             !(sc (mkTmpVar fc var))
           pure (Bind fc x b' sc')
  -- These are the names we invented when quoting the scope of a binder
  quoteGen s bounds env (VApp fc Bound (MN n i) sp val)
      = do sp' <- quoteSpine BlockApp bounds env sp
           case findName bounds of
                Just (MkVar p) =>
                    pure $ applySpine (Local fc Nothing _ (varExtend p)) sp'
                Nothing =>
                    pure $ applySpine (Ref fc Bound (MN n i)) sp'
    where
      findName : Bounds bound' -> Maybe (Var bound')
      findName None = Nothing
      findName (Add x (MN n' i') ns)
          = if i == i' -- this uniquely identifies it, given how we
                       -- generated the names, and is a faster test!
               then Just (MkVar First)
               else do MkVar p <-findName ns
                       Just (MkVar (Later p))
      findName (Add x _ ns)
          = do MkVar p <-findName ns
               Just (MkVar (Later p))
  quoteGen BlockApp bounds env (VApp fc nt n sp val)
      = do sp' <- quoteSpine BlockApp bounds env sp
           pure $ applySpine (Ref fc nt n) sp'
  quoteGen ExpandHoles bounds env (VApp fc nt n sp val)
      = do sp' <- quoteSpine ExpandHoles bounds env sp
           pure $ applySpine (Ref fc nt n) sp'
  quoteGen s bounds env (VApp fc nt n sp val)
      = do -- Reduce if it's visible in the current namespace
           True <- case getNS s of
                        Nothing => pure True
                        Just ns => do vis <- getVisibility fc n
                                      pure $ reducibleInAny ns n vis
              | False =>
                  do sp' <- quoteSpine s bounds env sp
                     pure $ applySpine (Ref fc nt n) sp'
           Just v <- val
              | Nothing =>
                  do sp' <- quoteSpine s bounds env sp
                     pure $ applySpine (Ref fc nt n) sp'
           case s of
             -- If the result is a binder, and we're in Binder mode, then
             -- keep going, otherwise just give back the application
                Binders =>
                    if !(isBinder v)
                       then quoteGen s bounds env v
                       else do sp' <- quoteSpine s bounds env sp
                               pure $ applySpine (Ref fc nt n) sp'
             -- If the result is blocked by a case/lambda then just give back
             -- the application for readability. Otherwise, keep quoting
                _ => if !(blockedApp v)
                        then do sp' <- quoteSpine s bounds env sp
                                pure $ applySpine (Ref fc nt n) sp'
                        else quoteGen s bounds env v
    where
      isBinder : Value f vars -> Core Bool
      isBinder (VLam fc _ _ _ _ sc) = pure True
      isBinder (VBind{}) = pure True
      isBinder _ = pure False

      blockedApp : Value f vars -> Core Bool
      blockedApp (VLam fc _ _ _ _ sc)
          = blockedApp !(sc (VErased fc Placeholder))
      blockedApp (VCase{}) = pure True
      blockedApp _ = pure False
  quoteGen {bound} s bounds env (VLocal fc mlet idx p sp)
      = do sp' <- quoteSpine s bounds env sp
           let MkVar p' = addLater bound p
           pure $ applySpine (Local fc mlet _ p') sp'
    where
      addLater : {idx : _} ->
                 (ys : SnocList Name) -> (0 p : IsVar n idx xs) ->
                 Var (xs ++ ys)
      addLater [<] isv = MkVar isv
      addLater (xs :< x) isv
          = let MkVar isv' = addLater xs isv in
                MkVar (Later isv')
  quoteGen BlockApp bounds env (VMeta fc n i args sp val)
      = do sp' <- quoteSpine BlockApp bounds env sp
           args' <- traverse (\ (q, val) =>
                                do val' <- quoteGen BlockApp bounds env val
                                   pure (q, val')) args
           pure $ applySpine (Meta fc n i args') sp'
  quoteGen s bounds env (VMeta fc n i args sp val)
      = do Just v <- val
              | Nothing =>
                  do sp' <- quoteSpine BlockApp bounds env sp
                     args' <- traverse (\ (q, val) =>
                                          do val' <- quoteGen BlockApp bounds env val
                                             pure (q, val')) args
                     pure $ applySpine (Meta fc n i args') sp'
           quoteGen s bounds env v
  quoteGen s bounds env (VDCon fc n t a sp)
      = do let s' = case s of
                         HNF _ => BlockApp
                         _ => s
           sp' <- quoteSpine s' bounds env sp
           pure $ applySpine (Ref fc (DataCon t a) n) sp'
  quoteGen s bounds env (VTCon fc n a sp)
      = do let s' = case s of
                         HNF _ => BlockApp
                         _ => s
           sp' <- quoteSpine s' bounds env sp
           pure $ applySpine (Ref fc (TyCon a) n) sp'
  quoteGen s bounds env (VAs fc use as pat)
      = do pat' <- quoteGen s bounds env pat
           as' <- quoteGen s bounds env as
           pure (As fc use as' pat')
  quoteGen s bounds env (VCase fc rig sc scTy alts)
      = do sc' <- quoteGen s bounds env sc
           scTy' <- quoteGen s bounds env scTy
           alts' <- traverse (quoteAlt BlockApp bounds env) alts
           pure $ Case fc rig sc' scTy' alts'
  quoteGen s bounds env (VDelayed fc r ty)
      = do ty' <- quoteGen s bounds env ty
           pure (TDelayed fc r ty')
  quoteGen s bounds env (VDelay fc r ty arg)
      = do ty' <- quoteGen BlockApp bounds env ty
           arg' <- quoteGen BlockApp bounds env arg
           pure (TDelay fc r ty' arg')
  quoteGen s bounds env (VForce fc r val sp)
      = do sp' <- quoteSpine s bounds env sp
           val' <- quoteGen s bounds env val
           pure $ applySpine (TForce fc r val') sp'
  quoteGen s bounds env (VPrimVal fc c) = pure $ PrimVal fc c
  quoteGen {vars} {bound} s bounds env (VPrimOp fc fn args)
      = do args' <- quoteArgs args
           pure $ PrimOp fc fn args'
    where
      -- No traverse for Vect in Core...
      quoteArgs : Vect n (Value f vars) -> Core (Vect n (Term (vars ++ bound)))
      quoteArgs [] = pure []
      quoteArgs (a :: as)
          = pure $ !(quoteGen s bounds env a) :: !(quoteArgs as)
  quoteGen s bounds env (VErased fc why) = Erased fc <$> traverse @{%search} @{CORE} (quoteGen s bounds env) why
  quoteGen s bounds env (VUnmatched fc str) = pure $ Unmatched fc str
  quoteGen s bounds env (VType fc n) = pure $ TType fc n

parameters {auto c : Ref Ctxt Defs}
  quoteStrategy : {vars : _} ->
            Strategy -> Env Term vars -> Value f vars -> Core (Term vars)
  quoteStrategy s env val
      = do q <- newRef QVar 0
           quoteGen s None env val

  export
  quoteNFall : {vars : _} ->
            Env Term vars -> Value f vars -> Core (Term vars)
  quoteNFall = quoteStrategy (NF Nothing)

  export
  quoteHNFall : {vars : _} ->
          Env Term vars -> Value f vars -> Core (Term vars)
  quoteHNFall = quoteStrategy (HNF Nothing)

  export
  quoteNF : {vars : _} ->
            Env Term vars -> Value f vars -> Core (Term vars)
  quoteNF env val
      = do defs <- get Ctxt
           quoteStrategy (NF (Just (currentNS defs :: nestedNS defs)))
                         env val

  export
  quoteHNF : {vars : _} ->
            Env Term vars -> Value f vars -> Core (Term vars)
  quoteHNF env val
      = do defs <- get Ctxt
           quoteStrategy (HNF (Just (currentNS defs :: nestedNS defs)))
                         env val

  -- Keep quoting while we're still going under binders
  export
  quoteBinders : {vars : _} ->
          Env Term vars -> Value f vars -> Core (Term vars)
  quoteBinders = quoteStrategy Binders

  export
  quoteHoles : {vars : _} ->
          Env Term vars -> Value f vars -> Core (Term vars)
  quoteHoles = quoteStrategy ExpandHoles

  export
  quote : {vars : _} ->
          Env Term vars -> Value f vars -> Core (Term vars)
  quote = quoteStrategy BlockApp
