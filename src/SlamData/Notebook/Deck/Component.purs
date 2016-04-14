{-
Copyright 2016 SlamData, Inc.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
-}

module SlamData.Notebook.Deck.Component
  ( deckComponent
  , initialState
  , module SlamData.Notebook.Deck.Component.Query
  , module SlamData.Notebook.Deck.Component.State
  ) where

import SlamData.Prelude

import Control.Monad.Aff.Console (log)
import Control.UI.Browser (newTab, locationObject)

import Data.Argonaut (Json)
import Data.Array (catMaybes, nub)
import Data.BrowserFeatures (BrowserFeatures)
import Data.Lens (LensP(), view, (.~), (%~), (?~), (^?))
import Data.Lens.Prism.Coproduct (_Right)
import Data.List as List
import Data.Map as Map
import Data.Path.Pathy ((</>))
import Data.Path.Pathy as Pathy
import Data.Set as S
import Data.String as Str
import Data.These (These(..), theseRight)
import Data.Time (Milliseconds(..))

import Ace.Halogen.Component as Ace

import DOM.HTML.Location as Location

import Halogen as H
import Halogen.Component.Utils (forceRerender')
import Halogen.HTML.Indexed as HH
import Halogen.Component.ChildPath (ChildPath, injSlot, injState)
import Halogen.HTML.Properties.Indexed as HP
import Halogen.HTML.Events.Indexed as HE
import Halogen.Themes.Bootstrap3 as B
import Halogen.HTML.Properties.Indexed.ARIA as ARIA

import Quasar.Aff as Quasar
import Quasar.Auth as Auth

import SlamData.Config as Config
import SlamData.Effects (Slam)
import SlamData.FileSystem.Resource as R
import SlamData.Notebook.AccessType (AccessType(..), isEditable)
import SlamData.Notebook.Action as NA
import SlamData.Notebook.Cell.CellId (CellId(), cellIdToString)
import SlamData.Notebook.Cell.CellType
  (CellType(..), AceMode(..), cellName, cellGlyph, autorun, nextCellTypes)
import SlamData.Notebook.Cell.Common.EvalQuery (CellEvalQuery(..))
import SlamData.Notebook.Cell.Component
  (CellQueryP(), CellQuery(..), InnerCellQuery, CellStateP, AnyCellQuery(..), _NextQuery, initEditorCellState)
import SlamData.Notebook.Cell.Next.Component as Next
import SlamData.Notebook.Cell.Port (Port(..))
import SlamData.Notebook.Deck.Component.Query (QueryP, Query(..))
import SlamData.Notebook.Deck.Component.State (CellConstructor, CellDef, DebounceTrigger, State, StateP, StateMode(..), _accessType, _activeCellId, _browserFeatures, _cells, _dependencies, _fresh, _globalVarMap, _name, _path, _pendingCells, _runTrigger, _saveTrigger, _stateMode, _viewingCell, _backsided, addCell, addCell', addPendingCell, cellIsLinkedCellOf, cellsOfType, findChildren, findDescendants, findParent, findRoot, fromModel, getCellType, initialDeck, notebookPath, removeCells, findLast, findLastCellType)
import SlamData.Notebook.Deck.Model as Model
import SlamData.Notebook.FileInput.Component as Fi
import SlamData.Notebook.Routing (mkNotebookHash, mkNotebookCellHash, mkNotebookURL)
import SlamData.Render.Common (glyph, fadeWhen)
import SlamData.Render.CSS as CSS
import SlamData.Notebook.Deck.Component.ChildSlot (cpBackSide, cpCell, ChildQuery, ChildState, ChildSlot, CellSlot(..))
import SlamData.Notebook.Deck.BackSide.Component as Back


import Utils.Debounced (debouncedEventSource)
import Utils.Path (DirPath)

type NotebookHTML = H.ParentHTML ChildState Query ChildQuery Slam ChildSlot
type NotebookDSL = H.ParentDSL State ChildState Query ChildQuery Slam ChildSlot

initialState ∷ BrowserFeatures → StateP
initialState fs = H.parentState $ initialDeck fs

deckComponent ∷ H.Component StateP QueryP Slam
deckComponent = H.parentComponent { render, eval, peek: Just peek }

render ∷ State → NotebookHTML
render state =
  case state.stateMode of
    Loading →
      HH.div
        [ HP.classes [ B.alert, B.alertInfo ] ]
        [ HH.h1
          [ HP.class_ B.textCenter ]
          [ HH.text "Loading..." ]
          -- We need to render the cells but have them invisible during loading
          -- otherwise the various nested components won't initialise correctly
        , renderCells false
        ]
    Ready →
      -- WARNING: Very strange things happen when this is not in a div; see SD-1326.
      HH.div_
        $ [ renderCells $ not state.backsided
          , renderBackside state.backsided
            -- Commented until one card representation
--          , HH.button [ HP.classes [ B.btn, B.btnPrimary ]
--                      , HE.onClick (HE.input_ FlipDeck)
--                      , ARIA.label "Flip deck"
--                      ]
--            [ HH.text "Flip" ]
          ]

    Error err →
      HH.div
        [ HP.classes [ B.alert, B.alertDanger ] ]
        [ HH.h1
            [ HP.class_ B.textCenter ]
            [ HH.text err ]
        ]

  where
  renderBackside visible =
    HH.div
      ( [ ARIA.hidden $ show $ not visible ]
        ⊕ ((guard $ not visible) $> (HP.class_ CSS.invisible)))

      [ HH.slot' cpBackSide unit \_ →
         { component: Back.comp
         , initialState: Back.initialState
         }
      ]


  renderCells visible =
    -- The key here helps out virtual-dom: the entire subtree will be moved
    -- when the loading message disappears, rather than being reconstructed in
    -- the parent element
    HH.div
      ([ HP.key "notebook-cells"]
       ⊕ (guard (not visible) $> (HP.class_ CSS.invisible)))
      ( List.fromList (map renderCell state.cells)
        ⊕ (pure $ newCellMenu state)
      )

  renderCell cellDef =
    HH.div
    ([ HP.key ("cell" ⊕ cellIdToString cellDef.id) ]
     ⊕ foldMap (viewingStyle cellDef) state.viewingCell)
    [ HH.Slot $ transformCellConstructor cellDef.ctor ]

  transformCellConstructor (H.SlotConstructor p l) =
    H.SlotConstructor
      (injSlot cpCell p)
      (l <#> \def →
        { component: H.transformChild cpCell def.component
        , initialState: injState cpCell def.initialState
        }
      )

  viewingStyle cellDef cid =
    guard (not (cellDef.id ≡ cid))
    *> guard (not (cellIsLinkedCellOf { childId: cellDef.id, parentId: cid} state))
    $> (HP.class_ CSS.invisible)

  shouldHideNextAction =
    isJust state.viewingCell ∨ state.accessType ≡ ReadOnly

  newCellMenu state =
    HH.div
      ([ HP.key ("next-action-card") ]
       ⊕ (guard shouldHideNextAction $> (HP.class_ CSS.invisible)))

    [ HH.slot' cpCell (CellSlot top) \_ →
       { component: Next.nextCellComponent
       , initialState: H.parentState $ initEditorCellState
       }
    ]

eval ∷ Natural Query NotebookDSL
eval (AddCell cellType next) = createCell cellType $> next
eval (RunActiveCell next) =
  (maybe (pure unit) runCell =<< H.gets (_.activeCellId)) $> next
eval (LoadNotebook fs dir next) = do
  H.modify (_stateMode .~ Loading)
  json ← H.fromAff $ Auth.authed $ Quasar.load $ dir </> Pathy.file "index"
  case Model.decode =<< json of
    Left err → do
      H.fromAff $ log err
      H.modify (_stateMode .~
                Error "There was a problem decoding the saved notebook")
    Right model →
      let peeledPath = Pathy.peel dir
          path = fst <$> peeledPath
          name = either Just (const Nothing) ∘ snd =<< peeledPath
      in case fromModel fs path name model of
        Tuple cells st → do
          H.set st
          forceRerender'
          ranCells ← catMaybes <$> for cells \cell → do
            H.query' cpCell  (CellSlot cell.cellId)
              $ left
              $ H.action
              $ LoadCell cell
            pure if cell.hasRun then Just cell.cellId else Nothing
          -- We only need to run the root node in each subgraph, as doing so
          -- will result in all child nodes being run also as the outputs
          -- propagate down each subgraph.
          traverse_ runCell $ nub $ flip findRoot st <$> ranCells
          H.modify (_stateMode .~ Ready)
  updateNextActionCell
  pure next

eval (ExploreFile fs res next) = do
  H.set $ initialDeck fs
  H.modify
    $ (_path .~ Pathy.parentDir res)
    ∘ (addCell Explore Nothing)
  forceRerender'
  H.query' cpCell (CellSlot zero)
    $ right
    $ H.ChildF unit
    $ right
    $ ExploreQuery
    $ right
    $ H.ChildF unit
    $ H.action
    $ Fi.SelectFile
    $ R.File res
  forceRerender'
  runCell zero
  updateNextActionCell
  pure next
eval (Publish next) = do
  H.gets notebookPath >>= \mpath → do
    for_ mpath $ H.fromEff ∘ newTab ∘ flip mkNotebookURL (NA.Load ReadOnly)
  pure next
eval (Reset fs dir next) = do
  let
    nb = initialDeck fs
    peeledPath = Pathy.peel dir
    path = fst <$> peeledPath
    name = maybe nb.name This (either Just (const Nothing) ∘ snd =<< peeledPath)
  H.set $ nb { path = path, name = name }
  pure next
eval (SetName name next) =
  H.modify (_name %~ \n → case n of
             That _ → That name
             Both d _ → Both d name
             This d → Both d name
         ) $> next
eval (SetAccessType aType next) = do
  cids ← map Map.keys $ H.gets _.cellTypes
  for_ cids \cellId →
    void
      $ H.query' cpCell (CellSlot cellId)
      $ left
      $ H.action
      $ SetCellAccessType aType
  H.modify (_accessType .~ aType)
  unless (isEditable aType)
    $ H.modify (_backsided .~ false)
  pure next
eval (GetNotebookPath k) = k <$> H.gets notebookPath
eval (SetViewingCell mbcid next) = H.modify (_viewingCell .~ mbcid) $> next
eval (SaveNotebook next) = saveNotebook unit $> next
eval (RunPendingCells next) = runPendingCells unit $> next
eval (GetGlobalVarMap k) = k <$> H.gets _.globalVarMap
eval (SetGlobalVarMap m next) = do
  st ← H.get
  when (m ≠ st.globalVarMap) do
    H.modify (_globalVarMap .~ m)
    traverse_ runCell $ cellsOfType API st
  pure next
eval (FindCellParent cid k) = k <$> H.gets (findParent cid)
eval (GetCellType cid k) = k <$> H.gets (getCellType cid)
eval (FlipDeck next) = H.modify (_backsided %~ not) $> next
eval (GetActiveCellId k) = map k $ H.gets findLast


peek ∷ ∀ a. H.ChildF ChildSlot ChildQuery a → NotebookDSL Unit
peek (H.ChildF s q) =
  coproduct
    (either peekCells (\_ _ → pure unit) s)
    peekBackSide
    q

peekBackSide ∷ ∀ a. Back.Query a → NotebookDSL Unit
peekBackSide (Back.UpdateFilter _ _) = pure unit
peekBackSide (Back.DoAction action _) = case action of
  Back.Trash → do
    activeId ← H.gets _.activeCellId
    lastId ← H.gets findLast
    for_ (activeId <|> lastId) \trashId → do
      descendants ← H.gets (findDescendants trashId)
      H.modify $ removeCells (S.insert trashId descendants)
      triggerSave unit
      updateNextActionCell
      H.modify (_backsided .~ false)
  Back.Share → pure unit
  Back.Embed → pure unit
  Back.Publish →
    H.gets notebookPath >>= \mpath → do
      for_ mpath $ H.fromEff ∘ newTab ∘ flip mkNotebookURL (NA.Load ReadOnly)
  Back.Mirror → pure unit
  Back.Wrap → pure unit

peekCells ∷ ∀ a. CellSlot → CellQueryP a → NotebookDSL Unit
peekCells (CellSlot cellId) q =
  coproduct (peekCell cellId) (peekCellInner cellId) q


-- | Peek on the cell component to observe actions from the cell control
-- | buttons.
peekCell ∷ ∀ a. CellId → CellQuery a → NotebookDSL Unit
peekCell cellId q = case q of
  RunCell _ → runCell cellId
  RefreshCell _ → runCell ∘ findRoot cellId =<< H.get
  TrashCell _ → do
    descendants ← H.gets (findDescendants cellId)
    H.modify $ removeCells (S.insert cellId descendants)
    triggerSave unit
    updateNextActionCell
  ToggleCaching _ →
    triggerSave unit
  ShareCell _ → pure unit
  StopCell _ → do
    H.modify $ _runTrigger .~ Nothing
    H.modify $ _pendingCells %~ S.delete cellId
    runPendingCells unit
  _ → pure unit


updateNextActionCell ∷ NotebookDSL Unit
updateNextActionCell = do
  cid ← H.gets findLast
  mbMessage ← case cid of
    Just cellId → do
      out ←
        map join
          $ H.query' cpCell (CellSlot cellId)
          $ left (H.request GetOutput)
      pure $ case out of
        Nothing →
          Just "Next actions will be made available once the last card has been run"
        Just Blocked →
          Just "There are no available next actions"
        _ → Nothing
    Nothing → pure Nothing
  queryNextActionCard
    $ H.action
    $ Next.SetMessage mbMessage

  lastCellType ← H.gets findLastCellType
  queryNextActionCard
    $ H.action
    $ Next.SetAvailableTypes
    $ nextCellTypes lastCellType
  pure unit
  where
  queryNextActionCard q =
    H.query' cpCell (CellSlot top)
      $ right
      $ H.ChildF unit
      $ right
      $ NextQuery
      $ right q


createCell ∷ CellType → NotebookDSL Unit
createCell cellType = do
  cid ← H.gets findLast
  case cid of
    Nothing →
      H.modify (addCell cellType Nothing)
    Just cellId → do
      Tuple st newCellId ← H.gets $ addCell' cellType (Just cellId)
      H.set st
      forceRerender'
      input ←
        map join $ H.query' cpCell (CellSlot cellId) $ left (H.request GetOutput)

      for_ input \input' → do
        path ← H.gets notebookPath
        let setupInfo = { notebookPath: path, inputPort: input', cellId: newCellId }
        void
          $ H.query' cpCell  (CellSlot newCellId)
          $ right
          $ H.ChildF unit
          $ left
          $ H.action (SetupCell setupInfo)
      runCell newCellId
  updateNextActionCell
  triggerSave unit

-- | Peek on the inner cell components to observe `NotifyRunCell`, which is
-- | raised by actions within a cell that should cause the cell to run.
peekCellInner
  ∷ ∀ a. CellId → H.ChildF Unit InnerCellQuery a → NotebookDSL Unit
peekCellInner cellId (H.ChildF _ q) =
  coproduct (peekEvalCell cellId) (peekAnyCell cellId) q

peekEvalCell ∷ ∀ a. CellId → CellEvalQuery a → NotebookDSL Unit
peekEvalCell cellId (NotifyRunCell _) = runCell cellId
peekEvalCell _ _ = pure unit

peekAnyCell ∷ ∀ a. CellId → AnyCellQuery a → NotebookDSL Unit
peekAnyCell cellId q = do
  for_ (q ^? _NextQuery ∘ _Right ∘ Next._AddCellType) createCell
  when (queryShouldRun q) $ runCell cellId
  when (queryShouldSave q) $ triggerSave unit
  pure unit

queryShouldRun ∷ ∀ a. AnyCellQuery a → Boolean
queryShouldRun (SaveQuery q) = false
queryShouldRun _ = true

queryShouldSave  ∷ ∀ a. AnyCellQuery a → Boolean
queryShouldSave (AceQuery q) =
  coproduct evalQueryShouldSave aceQueryShouldSave q
queryShouldSave _ = true

evalQueryShouldSave ∷ ∀ a. CellEvalQuery a → Boolean
evalQueryShouldSave _ = true

aceQueryShouldSave
  ∷ ∀ p a. H.ChildF p Ace.AceQuery a → Boolean
aceQueryShouldSave (H.ChildF _ q) =
  case q of
    Ace.TextChanged _ → true
    _ → false


-- | Runs all cell that are present in the set of pending cells.
runPendingCells ∷ Unit → NotebookDSL Unit
runPendingCells _ = do
  cells ← H.gets _.pendingCells
  traverse_ runCell' cells
  updateNextActionCell
  where
  runCell' ∷ CellId → NotebookDSL Unit
  runCell' cellId = do
    mbParentId ← H.gets (findParent cellId)
    case mbParentId of
      -- if there's no parent there's no input port value to pass through
      Nothing → updateCell Nothing cellId
      Just parentId → do
        value ←
          map join $ H.query' cpCell (CellSlot parentId) $ left (H.request GetOutput)
        case value of
          -- if there's a parent but no output the parent cell hasn't been evaluated
          -- yet, so we can't run this cell either
          Nothing → pure unit
          -- if there's a parent and an output, pass it on as this cell's input
          Just p → updateCell (Just p) cellId
    H.modify $ _pendingCells %~ S.delete cellId
    triggerSave unit

-- | Enqueues the cell with the specified ID in the set of cells that are
-- | pending to run and enqueues a debounced H.query to trigger the cells to
-- | actually run.
runCell ∷ CellId → NotebookDSL Unit
runCell cellId = do
  H.modify (addPendingCell cellId)
  _runTrigger `fireDebouncedQuery` RunPendingCells

-- | Updates the evaluated value for a cell by running it with the specified
-- | input and then runs any cells that depend on the cell's output with the
-- | new result.
updateCell ∷ Maybe Port → CellId → NotebookDSL Unit
updateCell inputPort cellId = do
  path ← H.gets notebookPath
  globalVarMap ← H.gets _.globalVarMap
  let input = { notebookPath: path, inputPort, cellId, globalVarMap }
  result ←
    map join
      $ H.query' cpCell (CellSlot cellId)
      $ left
      $ H.request (UpdateCell input)

  runCellDescendants cellId (fromMaybe Blocked result)
  where
  runCellDescendants ∷ CellId → Port → NotebookDSL Unit
  runCellDescendants parentId value = do
    children ← H.gets (findChildren parentId)
    traverse_ (updateCell (Just value)) children

-- | Triggers the H.query for autosave. This does not immediate perform the save
-- | H.action, but instead enqueues a debounced H.query to trigger the actual save.
triggerSave ∷ Unit → NotebookDSL Unit
triggerSave _ =
  _saveTrigger `fireDebouncedQuery` SaveNotebook

-- | Fires the specified debouced H.query trigger with the passed H.query. This
-- | function also handles constructing the initial trigger if it has not yet
-- | been created.
fireDebouncedQuery
  ∷ LensP State (Maybe DebounceTrigger)
  → H.Action Query
  → NotebookDSL Unit
fireDebouncedQuery lens act = do
  t ← H.gets (view lens) >>= \mbt → case mbt of
    Just t' → pure t'
    Nothing → do
      t' ← debouncedEventSource H.fromEff H.subscribe' (Milliseconds 500.0)
      H.modify (lens ?~ t')
      pure t'
  H.liftH $ H.liftH $ t $ H.action $ act

-- | Saves the notebook as JSON, using the current values present in the state.
saveNotebook ∷ Unit → NotebookDSL Unit
saveNotebook _ = H.get >>= \st → do
  unless (isUnsaved st ∧ isNewExploreNotebook st) do
    for_ st.path \path → do
      cells ← catMaybes <$> for (List.fromList st.cells) \cell →
        H.query' cpCell (CellSlot cell.id)
          $ left
          $ H.request (SaveCell cell.id cell.ty)

      let json = Model.encode { cells, dependencies: st.dependencies }

      savedName ← case st.name of
        This name → save path name json
        That name → do
          newName ← getNewName' path name
          save path newName json
        Both oldName newName → do
          save path oldName json
          if newName ≡ nameFromDirName oldName
            then pure oldName
            else rename path oldName newName

      H.modify (_name .~ This savedName)
      -- We need to get the modified version of the notebook state.
      H.gets notebookPath >>= traverse_ \path' →
        let notebookHash =
              case st.viewingCell of
                Nothing →
                  mkNotebookHash path' (NA.Load st.accessType) st.globalVarMap
                Just cid →
                  mkNotebookCellHash path' cid st.accessType st.globalVarMap
        in H.fromEff $ locationObject >>= Location.setHash notebookHash

  where

  isUnsaved ∷ State → Boolean
  isUnsaved = isNothing ∘ notebookPath

  isNewExploreNotebook ∷ State → Boolean
  isNewExploreNotebook { name, cells } =
    let
      cellArrays = List.toUnfoldable (map _.ty cells)
      nameHasntBeenModified = theseRight name ≡ Just Config.newNotebookName
    in
      nameHasntBeenModified
      ∧ (cellArrays ≡ [ Explore ] ∨ cellArrays ≡ [ Explore, JTable ])

  -- Finds a new name for a notebook in the specified parent directory, using
  -- a name value as a basis to start with.
  getNewName' ∷ DirPath → String → NotebookDSL Pathy.DirName
  getNewName' dir name =
    let baseName = name ⊕ "." ⊕ Config.notebookExtension
    in H.fromAff $ Pathy.DirName <$> Auth.authed (Quasar.getNewName dir baseName)

  -- Saves a notebook and returns the name it was saved as.
  save ∷ DirPath → Pathy.DirName → Json → NotebookDSL Pathy.DirName
  save dir name json = do
    let notebookPath = dir </> Pathy.dir' name </> Pathy.file "index"
    H.fromAff $ Auth.authed $ Quasar.save notebookPath json
    pure name

  -- Renames a notebook and returns the new name it was changed to.
  rename ∷ DirPath → Pathy.DirName → String → NotebookDSL Pathy.DirName
  rename dir oldName newName = do
    newName' ← getNewName' dir newName
    let oldPath = dir </> Pathy.dir' oldName
        newPath = dir </> Pathy.dir' newName'
    H.fromAff $ Auth.authed $ Quasar.move (R.Directory oldPath) (Right newPath)
    pure newName'

-- | Takes a `DirName` for a saved notebook and returns the name part without
-- | the `.slam` extension.
nameFromDirName ∷ Pathy.DirName → String
nameFromDirName dirName =
  let name = Pathy.runDirName dirName
  in Str.take (Str.length name - Str.length Config.notebookExtension - 1) name