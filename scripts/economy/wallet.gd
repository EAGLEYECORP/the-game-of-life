class_name Wallet
extends Node
## The player's money, in Moroccan dirhams (DH).
##
## Everything that pays or costs goes through earn() / spend(), so the HUD can
## show "+400 DH" / "-150 DH" popups and the total is saved with the game.

signal money_changed(total: int, delta: int, reason: String)

@export var starting_money := 500

var money := 0
## Lifetime totals, for the save file and future stats screens.
var total_earned := 0
var total_spent := 0


func _ready() -> void:
	var save := SaveGame.load_data()
	money = int(save.get("money", starting_money))
	total_earned = int(save.get("total_earned", 0))
	total_spent = int(save.get("total_spent", 0))
	money_changed.emit.call_deferred(money, 0, "")


func earn(amount: int, reason := "") -> void:
	if amount <= 0:
		return
	money += amount
	total_earned += amount
	money_changed.emit(money, amount, reason)
	_save()


func can_afford(amount: int) -> bool:
	return money >= amount


## Takes `amount` if there's enough. Returns false (and takes nothing) if not.
func spend(amount: int, reason := "") -> bool:
	if amount <= 0:
		return true
	if money < amount:
		return false
	money -= amount
	total_spent += amount
	money_changed.emit(money, -amount, reason)
	_save()
	return true


## Takes up to `amount` (fines can't push you below zero). Returns what was taken.
func fine(amount: int, reason := "") -> int:
	var taken := mini(amount, money)
	if taken > 0:
		spend(taken, reason)
	return taken


## "12 500 DH" (Moroccan style: space as thousands separator).
static func format(amount: int) -> String:
	var s := str(absi(amount))
	var out := ""
	while s.length() > 3:
		out = " " + s.right(3) + out
		s = s.left(s.length() - 3)
	return ("-" if amount < 0 else "") + s + out + " DH"


func _save() -> void:
	SaveGame.store({"money": money, "total_earned": total_earned, "total_spent": total_spent})
