extends Node
## MatchState — переживает reload_current_scene() (autoload не пересоздаётся при рестарте
## Main.tscn, в отличие от @export-полей на нодах внутри самой сцены). Единственное поле —
## какая команда сейчас у игрока; TeamSpawner читает его вместо своего бывшего
## @export var player_team. Меняется на противоположную при нажатии кнопки рестарта в HUD
## (см. hud.gd) — команды меняются сторонами каждый новый раунд.

var player_team: int = 0  # 0 = Tank.Team.ATTACK, 1 = Tank.Team.DEFENSE
