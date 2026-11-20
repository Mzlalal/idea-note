enum PanelAction {
  case none, show, hide
}

func panelAction(enabled: Bool, visible: Bool) -> PanelAction {
  guard enabled else { return .none }
  return visible ? .hide : .show
}

func shouldDismissPanel(pinned: Bool, peerHasFocus: Bool) -> Bool {
  !pinned && !peerHasFocus
}
