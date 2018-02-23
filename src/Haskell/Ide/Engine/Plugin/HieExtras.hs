{-# LANGUAGE CPP                 #-}
{-# LANGUAGE NamedFieldPuns      #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings   #-}
module Haskell.Ide.Engine.Plugin.HieExtras
  ( getDynFlags
  , getSymbols
  , getCompletions
  , getTypeForName
  , getSymbolsAtPoint
  , getReferencesInDoc
  , getModule
  , findDef
  , showName
  ) where

import           ConLike
import           Control.Monad.State
import           Control.Monad.Trans.Except
import           Data.Aeson
import           Data.Either
import           Data.IORef
import qualified Data.Map                                     as Map
import           Data.Maybe
import           Data.Monoid
import qualified Data.Set                                     as Set
import qualified Data.Text                                    as T
import           Data.Typeable
import           DataCon
import           Exception
import           FastString
import           GHC
import qualified GhcMod.Error                                 as GM
import qualified GhcMod.Monad                                 as GM
import qualified GhcMod.LightGhc                              as GM
import           Haskell.Ide.Engine.ArtifactMap
import           Haskell.Ide.Engine.MonadFunctions
import           Haskell.Ide.Engine.MonadTypes
import           Haskell.Ide.Engine.PluginUtils
import           Haskell.Ide.Engine.Plugin.GhcMod            (setTypecheckedModule)
import           HscTypes
import qualified Language.Haskell.LSP.TH.DataTypesJSON        as J
import           Language.Haskell.Refact.API                 (showGhcQual, setGhcContext, hsNamessRdr)
import           Language.Haskell.Refact.Utils.MonadFunctions
import           Module                                       hiding (getModule)
import           Name
import           Outputable                                   (Outputable)
import qualified Outputable                                   as GHC
import qualified DynFlags                                     as GHC
import           Packages
import           SrcLoc
import           TcEnv
import           Var

getDynFlags :: Uri -> IdeM (IdeResponse DynFlags)
getDynFlags uri =
  pluginGetFile "getDynFlags: " uri $ \fp -> do
      mcm <- getCachedModule fp
      case mcm of
        Just cm -> return $
          IdeResponseOk $ ms_hspp_opts $ pm_mod_summary $ tm_parsed_module $ tcMod cm
        Nothing -> return $
          IdeResponseFail $
            IdeError PluginError ("getDynFlags: \"" <> "module not loaded" <> "\"") Null

-- ---------------------------------------------------------------------

nonExistentCacheErr :: String -> IdeResponse a
nonExistentCacheErr meth =
  IdeResponseFail $
    IdeError PluginError
             (T.pack $ meth <> ": \"" <> "module not loaded" <> "\"")
             Null

someErr :: String -> String -> IdeResponse a
someErr meth err =
  IdeResponseFail $
    IdeError PluginError
             (T.pack $ meth <> ": " <> err)
             Null

-- ---------------------------------------------------------------------

data NameMapData = NMD
  { inverseNameMap ::  !(Map.Map Name [SrcSpan])
  } deriving (Typeable)

invert :: (Ord v) => Map.Map k v -> Map.Map v [k]
invert m = Map.fromListWith (++) [(v,[k]) | (k,v) <- Map.toList m]

instance ModuleCache NameMapData where
  cacheDataProducer cm = pure $ NMD inm
    where nm  = initRdrNameMap $ tcMod cm
          inm = invert nm

-- ---------------------------------------------------------------------

getSymbols :: Uri -> IdeM (IdeResponse [J.SymbolInformation])
getSymbols uri = pluginGetFile "getSymbols: " uri $ \file -> do
    mcm <- getCachedModule file
    case mcm of
      Nothing -> return $ IdeResponseOk []
      Just cm -> do
          let tm = tcMod cm
              rfm = revMap cm
              hsMod = unLoc $ pm_parsed_source $ tm_parsed_module tm
              imports = hsmodImports hsMod
              imps  = concatMap (goImport . unLoc) imports
              decls = concatMap (go . unLoc) $ hsmodDecls hsMod
              s x = showName <$> x

              go :: HsDecl RdrName -> [(J.SymbolKind,Located T.Text,Maybe T.Text)]
              go (TyClD FamDecl { tcdFam = FamilyDecl { fdLName = n } }) = pure (J.SkClass, s n, Nothing)
              go (TyClD SynDecl { tcdLName = n }) = pure (J.SkClass, s n, Nothing)
              go (TyClD DataDecl { tcdLName = n, tcdDataDefn = HsDataDefn { dd_cons = cons } }) =
                (J.SkClass, s n, Nothing) : concatMap (processCon (unLoc $ s n) . unLoc) cons
              go (TyClD ClassDecl { tcdLName = n, tcdSigs = sigs, tcdATs = fams }) =
                (J.SkInterface, sn, Nothing) :
                      concatMap (processSig (unLoc sn) . unLoc) sigs
                  ++  concatMap (map setCnt . go . TyClD . FamDecl . unLoc) fams
                where sn = s n
                      setCnt (k,n',_) = (k,n',Just (unLoc sn))
              go (ValD FunBind { fun_id = ln }) = pure (J.SkFunction, s ln, Nothing)
              go (ValD PatBind { pat_lhs = p }) =
                map (\n ->(J.SkMethod, s n, Nothing)) $ hsNamessRdr p
              go (ForD ForeignImport { fd_name = n }) = pure (J.SkFunction, s n, Nothing)
              go _ = []

              processSig :: T.Text
                         -> Sig RdrName
                         -> [(J.SymbolKind, Located T.Text, Maybe T.Text)]
              processSig cnt (ClassOpSig False names _) =
                map (\n ->(J.SkMethod,s n, Just cnt)) names
              processSig _ _ = []

              processCon :: T.Text
                         -> ConDecl RdrName
                         -> [(J.SymbolKind, Located T.Text, Maybe T.Text)]
              processCon cnt ConDeclGADT { con_names = names } =
                map (\n -> (J.SkConstructor, s n, Just cnt)) names
              processCon cnt ConDeclH98 { con_name = name, con_details = dets } =
                (J.SkConstructor, sn, Just cnt) : xs
                where
                  sn = s name
                  xs = case dets of
                    RecCon (L _ rs) -> concatMap (map (f . rdrNameFieldOcc . unLoc)
                                                 . cd_fld_names
                                                 . unLoc) rs
                                         where f ln = (J.SkField, s ln, Just (unLoc sn))
                    _ -> []

              goImport :: ImportDecl RdrName -> [(J.SymbolKind, Located T.Text, Maybe T.Text)]
              goImport ImportDecl { ideclName = lmn, ideclAs = as, ideclHiding = meis } = a ++ xs
                where
                  im = (J.SkModule, lsmn, Nothing)
                  lsmn = s lmn
                  smn = unLoc lsmn
                  a = case as of
                            Just a' -> [(J.SkNamespace, lsmn, Just $ showName a')]
                            Nothing -> [im]
                  xs = case meis of
                         Just (False, eis) -> concatMap (f . unLoc) (unLoc eis)
                         _ -> []
                  f (IEVar n) = pure (J.SkFunction, s n, Just smn)
                  f (IEThingAbs n) = pure (J.SkClass, s n, Just smn)
                  f (IEThingAll n) = pure (J.SkClass, s n, Just smn)
                  f (IEThingWith n _ vars fields) =
                    let sn = s n in
                    (J.SkClass, sn, Just smn) :
                         map (\n' -> (J.SkFunction, s n', Just (unLoc sn))) vars
                      ++ map (\f' -> (J.SkField   , s f', Just (unLoc sn))) fields
                  f _ = []

              declsToSymbolInf :: (J.SymbolKind, Located T.Text, Maybe T.Text)
                               -> IdeM (Either T.Text J.SymbolInformation)
              declsToSymbolInf (kind, L l nameText, cnt) = do
                eloc <- srcSpan2Loc rfm l
                case eloc of
                  Left x -> return $ Left x
                  Right loc -> return $ Right $ J.SymbolInformation nameText kind loc cnt
          symInfs <- mapM declsToSymbolInf (imps ++ decls)
          return $ IdeResponseOk $ rights symInfs

-- ---------------------------------------------------------------------

data CompItem = CI
  { origName     :: Name
  , importedFrom :: T.Text
  , thingType    :: Maybe T.Text
  , label        :: T.Text
  }

instance Eq CompItem where
  (CI n1 _ _ _) == (CI n2 _ _ _) = n1 == n2

instance Ord CompItem where
  compare (CI n1 _ _ _) (CI n2 _ _ _) = compare n1 n2

occNameToComKind :: OccName -> J.CompletionItemKind
occNameToComKind oc
  | isVarOcc  oc = J.CiFunction
  | isTcOcc   oc = J.CiClass
  | isDataOcc oc = J.CiConstructor
  | otherwise    = J.CiVariable

type HoogleQuery = T.Text

mkQuery :: T.Text -> T.Text -> HoogleQuery
mkQuery name importedFrom = name <> " module:" <> importedFrom
                                 <> " is:exact"

mkCompl :: CompItem -> J.CompletionItem
mkCompl CI{origName,importedFrom,thingType,label} =
  J.CompletionItem label kind (Just $ maybe "" (<>"\n") thingType <> importedFrom)
    Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing hoogleQuery
  where kind  = Just $ occNameToComKind $ occName origName
        hoogleQuery = Just $ toJSON $ mkQuery label importedFrom

mkModCompl :: T.Text -> J.CompletionItem
mkModCompl label =
  J.CompletionItem label (Just J.CiModule) Nothing
    Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing hoogleQuery
  where hoogleQuery = Just $ toJSON $ "module:" <> label

safeTyThingId :: TyThing -> Maybe Id
safeTyThingId (AnId i)                    = Just i
safeTyThingId (AConLike (RealDataCon dc)) = Just $ dataConWrapId dc
safeTyThingId _                           = Nothing

getCompletions :: Uri -> (T.Text, T.Text) -> IdeM (IdeResponse [J.CompletionItem])
getCompletions uri (qualifier,ident) = pluginGetFile "getCompletions: " uri $ \file ->
  let handlers  = [GM.GHandler $ \(ex :: SomeException) ->
                     return $ someErr "getCompletions" (show ex)
                  ] in
  flip GM.gcatches handlers $ do
  debugm $ "got prefix" ++ show (qualifier,ident)
  let noCache = return $ nonExistentCacheErr "getCompletions"
  let modQual = if T.null qualifier then "" else qualifier <> "."
  let fullPrefix = modQual <> ident
  withCachedModule file noCache $
    \cm -> do
      let tm = tcMod cm
          parsedMod = tm_parsed_module tm
          curMod = moduleName $ ms_mod $ pm_mod_summary parsedMod
          Just (_,limports,_,_) = tm_renamed_source tm
          imports = map unLoc limports
          typeEnv = md_types $ snd $ tm_internals_ tm

          localVars = mapMaybe safeTyThingId $ typeEnvElts typeEnv
          localCmps = getCompls $ map varToLocalCmp localVars
          varToLocalCmp var = CI name (showMod curMod) typ label
            where typ = Just $ showName $ varType var
                  name = Var.varName var
                  label = showName name

          importMn = unLoc . ideclName
          showMod = T.pack . moduleNameString
          nameToCompItem mn n =
            CI n (showMod mn) Nothing $ showName n

          getCompls = filter ((ident `T.isPrefixOf`) . label)

#if __GLASGOW_HASKELL__ >= 802
          pickName imp = fromMaybe (importMn imp) (fmap GHC.unLoc $ ideclAs imp)
#else
          pickName imp = fromMaybe (importMn imp) (ideclAs imp)
#endif

          allModules = map (showMod . pickName) imports
          modCompls = map mkModCompl
                    $ mapMaybe (T.stripPrefix $ modQual)
                    $ filter (fullPrefix `T.isPrefixOf`) allModules

          unqualImports :: [ModuleName]
          unqualImports = map importMn
                        $ filter (not . ideclQualified) imports

          relevantImports :: [(ModuleName, Maybe (Bool, [Name]))]
          relevantImports
            | T.null qualifier = []
            | otherwise = mapMaybe f imports
              where f imp = do
                      let mn = importMn imp
                      guard (showMod (pickName imp) == qualifier)
                      case ideclHiding imp of
                        Nothing -> return (mn,Nothing)
                        Just (b,L _ liens) ->
                          return (mn, Just (b, concatMap (ieNames . unLoc) liens))

          getComplsFromModName :: GhcMonad m
            => ModuleName -> m (Set.Set CompItem)
          getComplsFromModName mn = do
            mminf <- getModuleInfo =<< findModule mn Nothing
            return $ case mminf of
              Nothing -> Set.empty
              Just minf ->
                Set.fromList $ getCompls $ map (nameToCompItem mn) $ modInfoExports minf

          getQualifedCompls :: GhcMonad m => m (Set.Set CompItem)
          getQualifedCompls = do
            xs <- forM relevantImports $
              \(mn, mie) ->
                case mie of
                  (Just (False, ns)) ->
                    return $ Set.fromList $ getCompls $ map (nameToCompItem mn) ns
                  (Just (True , ns)) -> do
                    exps <- getComplsFromModName mn
                    let hid = Set.fromList $ getCompls $ map (nameToCompItem mn) ns
                    return $ Set.difference exps hid
                  Nothing ->
                    getComplsFromModName mn
            return $ Set.unions xs

          setCiTypesForImported Nothing xs = liftIO $ pure xs
          setCiTypesForImported (Just hscEnv) xs =
            liftIO $ forM xs $ \ci@CI{origName} -> do
              mt <- (Just <$> lookupGlobal hscEnv origName)
                      `catch` \(_ :: SourceError) -> return Nothing
              let typ = do
                    t <- mt
                    tyid <- safeTyThingId t
                    return $ showName $ varType tyid
              return $ ci {thingType = typ}

      comps <- do
        hscEnvRef <- ghcSession <$> readMTS
        hscEnv <- liftIO $ traverse readIORef hscEnvRef
        if T.null qualifier then do
          let getComplsGhc = maybe (const $ pure Set.empty) (\env -> GM.runLightGhc env . getComplsFromModName) hscEnv
          xs <- Set.toList . Set.unions <$> mapM getComplsGhc unqualImports
          xs' <- setCiTypesForImported hscEnv xs
          return $ localCmps ++ xs'
        else do
          let getQualComplsGhc = maybe (pure Set.empty) (\env -> GM.runLightGhc env getQualifedCompls) hscEnv
          xs <- Set.toList <$> getQualComplsGhc
          setCiTypesForImported hscEnv xs
      return $ IdeResponseOk $ modCompls ++ map mkCompl comps

-- ---------------------------------------------------------------------

getTypeForName :: Name -> IdeM (Maybe Type)
getTypeForName n = do
  hscEnvRef <- ghcSession <$> readMTS
  mhscEnv <- liftIO $ traverse readIORef hscEnvRef
  case mhscEnv of
    Nothing -> return Nothing
    Just hscEnv -> do
      mt <- liftIO $ (Just <$> lookupGlobal hscEnv n)
                        `catch` \(_ :: SomeException) -> return Nothing
      return $ fmap varType $ safeTyThingId =<< mt

-- ---------------------------------------------------------------------

getSymbolsAtPoint :: Uri -> Position -> IdeM (IdeResponse [(Range, Name)])
getSymbolsAtPoint uri pos = pluginGetFile "getSymbolsAtPoint: " uri $ \file -> do
  let noCache = return $ nonExistentCacheErr "getSymbolAtPoint"
  withCachedModule file noCache $
    return . IdeResponseOk . getSymbolsAtPointPure pos

getSymbolsAtPointPure :: Position -> CachedModule -> [(Range,Name)]
getSymbolsAtPointPure pos cm = maybe [] (`getArtifactsAtPos` locMap cm) $ newPosToOld cm pos

symbolFromTypecheckedModule
  :: LocMap
  -> Position
  -> Maybe (Range, Name)
symbolFromTypecheckedModule lm pos =
  case getArtifactsAtPos pos lm of
    (x:_) -> pure x
    []    -> Nothing

-- ---------------------------------------------------------------------

getReferencesInDoc :: Uri -> Position -> IdeM (IdeResponse [J.DocumentHighlight])
getReferencesInDoc uri pos = pluginGetFile "getReferencesInDoc: " uri $ \file -> do
  let noCache = return $ nonExistentCacheErr "getReferencesInDoc"
  withCachedModuleAndData file noCache $
    \cm NMD{inverseNameMap} -> runExceptT $ do
      let lm = locMap cm
          pm = tm_parsed_module $ tcMod cm
          cfile = ml_hs_file $ ms_location $ pm_mod_summary pm
          mpos = newPosToOld cm pos
      case mpos of
        Nothing -> return []
        Just pos' -> fmap concat $
          forM (getArtifactsAtPos pos' lm) $ \(_,name) -> do
              let usages = fromMaybe [] $ Map.lookup name inverseNameMap
                  defn = nameSrcSpan name
                  defnInSameFile =
                    (unpackFS <$> srcSpanFileName_maybe defn) == cfile
                  makeDocHighlight :: SrcSpan -> Maybe J.DocumentHighlight
                  makeDocHighlight spn = do
                    let kind = if spn == defn then J.HkWrite else J.HkRead
                    let
                      foo (Left _) = Nothing
                      foo (Right r) = Just r
                    r <- foo $ srcSpan2Range spn
                    r' <- oldRangeToNew cm r
                    return $ J.DocumentHighlight r' (Just kind)
                  highlights
                    |    isVarOcc (occName name)
                      && defnInSameFile = mapMaybe makeDocHighlight (defn : usages)
                    | otherwise = mapMaybe makeDocHighlight usages
              return highlights

-- ---------------------------------------------------------------------

showName :: Outputable a => a -> T.Text
showName = T.pack . prettyprint
  where
    prettyprint x = GHC.renderWithStyle GHC.unsafeGlobalDynFlags (GHC.ppr x) style
#if __GLASGOW_HASKELL__ >= 802
    style = (GHC.mkUserStyle GHC.unsafeGlobalDynFlags GHC.neverQualify GHC.AllTheWay)
#else
    style = (GHC.mkUserStyle GHC.neverQualify GHC.AllTheWay)
#endif

getModule :: DynFlags -> Name -> Maybe (Maybe T.Text,T.Text)
getModule df n = do
  m <- nameModule_maybe n
  let uid = moduleUnitId m
  let pkg = showName . packageName <$> lookupPackage df uid
  return (pkg, T.pack $ moduleNameString $ moduleName m)

-- ---------------------------------------------------------------------

getNewNames :: GhcMonad m => Name -> m [Name]
getNewNames old = do
  let eqModules (Module pk1 mn1) (Module pk2 mn2) = mn1 == mn2 && pk1 == pk2
  gnames <- GHC.getNamesInScope
  let clientModule = GHC.nameModule old
  let clientInscopes = filter (\n -> eqModules clientModule (GHC.nameModule n)) gnames
  let newNames = filter (\n -> showGhcQual n == showGhcQual old) clientInscopes
  return newNames

findDef :: Uri -> Position -> IdeGhcM (IdeResponse [Location])
findDef uri pos = pluginGetFile "findDef: " uri $ \file -> do
  let noCache = return $ nonExistentCacheErr "hare:findDef"
  withCachedModule file noCache $
    \cm -> do
      let rfm = revMap cm
          lm = locMap cm
      case symbolFromTypecheckedModule lm =<< newPosToOld cm pos of
        Nothing -> return $ IdeResponseOk []
        Just pn -> do
          let n = snd pn
          case nameSrcSpan n of
            UnhelpfulSpan _ -> return $ IdeResponseOk []
            realSpan   -> do
              res <- srcSpan2Loc rfm realSpan
              case res of
                Right l@(J.Location luri range) ->
                  case oldRangeToNew cm range of
                    Just r  -> return $ IdeResponseOk [J.Location luri r]
                    Nothing -> return $ IdeResponseOk [l]
                Left x -> do
                  let failure = pure (IdeResponseFail
                                        (IdeError PluginError
                                                  ("hare:findDef" <> ": \"" <> x <> "\"")
                                                  Null))
                  case nameModule_maybe n of
                    Just m -> do
                      let mName = moduleName m
                      b <- GM.unGmlT $ isLoaded mName
                      if b then do
                        mLoc <- GM.unGmlT $ ms_location <$> getModSummary mName
                        case ml_hs_file mLoc of
                          Just fp -> do
                            cfp <- reverseMapFile rfm fp
                            mcm' <- getCachedModule cfp
                            rcm' <- case mcm' of
                              Just cmdl -> do
                                debugm "module already in cache in findDef"
                                return $ Just cmdl
                              Nothing -> do
                                debugm "setting cached module in findDef"
                                _ <- setTypecheckedModule $ filePathToUri cfp
                                getCachedModule cfp
                            case rcm' of
                              Nothing ->
                                return
                                  $ IdeResponseFail
                                  $ IdeError PluginError ("hare:findDef: failed to load module for " <> T.pack cfp) Null
                              Just cm' -> do
                                let modSum = pm_mod_summary $ tm_parsed_module $ tcMod cm'
                                    rfm'   = revMap cm'
                                newNames <- GM.unGmlT $ do
                                  setGhcContext modSum
                                  getNewNames n
                                eithers <- mapM (srcSpan2Loc rfm' . nameSrcSpan) newNames
                                case rights eithers of
                                  (l:_) -> return $ IdeResponseOk [l]
                                  []    -> failure
                          Nothing -> failure
                        else failure
                    Nothing -> failure