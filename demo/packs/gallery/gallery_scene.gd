extends Control

var _cards: Array[PanelContainer] = []


func _ready() -> void:
	for index in range(12):
		var node: Node = find_child("Tile%02d" % index, true, false)
		if node is PanelContainer:
			var card: PanelContainer = node
			_cards.append(card)
	resized.connect(_update_card_pivots)
	_update_card_pivots()


func _process(_delta: float) -> void:
	for index in range(_cards.size()):
		var card: PanelContainer = _cards[index]
		var pulse: float = sin(Time.get_ticks_msec() * 0.0014 + float(index) * 0.37) * 0.012
		var scale_value: float = 1.0 + pulse
		card.scale = Vector2(scale_value, scale_value)


func _update_card_pivots() -> void:
	for card in _cards:
		card.pivot_offset = card.size * 0.5
