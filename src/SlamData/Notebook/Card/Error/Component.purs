module SlamData.Notebook.Card.Error.Component where

import SlamData.Prelude
import SlamData.Effects (Slam)

import Data.Lens ((^?))
import Data.Lens as Lens

import SlamData.Notebook.Card.Common.EvalQuery as CEQ
import SlamData.Notebook.Card.CardType as CT
import SlamData.Notebook.Card.Component as CC
import SlamData.Notebook.Card.Error.Component.State as ECS
import SlamData.Notebook.Card.Error.Component.Query as ECQ
import SlamData.Notebook.Card.Port as Port
import SlamData.Render.CSS as CSS

import Halogen as H
import Halogen.HTML.Indexed as HH
import Halogen.HTML.Properties.Indexed as HP

type DSL = H.ComponentDSL ECS.State ECQ.QueryP Slam
type HTML = H.ComponentHTML ECQ.QueryP

comp ∷ CC.CardComponent
comp =
  CC.makeCardComponent
    { cardType: CT.ErrorCard
    , component: H.component { render, eval }
    , initialState: ECS.initialState
    , _State: CC._ErrorState
    , _Query: CC.makeQueryPrism CC._ErrorQuery
    }

render
  ∷ ECS.State
  → HTML
render st =
  case st.message of
    Just msg →
      HH.div
        [ HP.classes [ CSS.cardFailures ] ]
        [ HH.text msg ]
    Nothing →
      HH.text ""

eval ∷ ECQ.QueryP ~> DSL
eval = coproduct cardEval ECQ.initiality

cardEval ∷ CEQ.CardEvalQuery ~> DSL
cardEval q =
  case q of
    CEQ.EvalCard {inputPort} k →
      k <$> CEQ.runCardEvalT do
        lift ∘ H.modify ∘ Lens.set ECS._message $
          inputPort ^? Lens._Just ∘ Port._CardError
        pure $ Just Port.Blocked
    CEQ.SetupCard {inputPort} next → do
      H.modify ∘ Lens.set ECS._message $ inputPort ^? Port._CardError
      pure next
    CEQ.NotifyRunCard next →
      pure next
    CEQ.NotifyStopCard next →
      pure next
    CEQ.SetCanceler _ next →
      pure next
    CEQ.Save k →
      k ∘ ECS.encode
        <$> H.get
    CEQ.Load json next →
      for_ (ECS.decode json) H.set
        $> next
