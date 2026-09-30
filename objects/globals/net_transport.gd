class_name NetTransport
extends RefCounted
## Thin project-level transport seam for multiplayer (TGM-38, architecture D2).
##
## A transport is only a factory for a configured [MultiplayerPeer]. Everything
## above it (RPCs, spawners, synchronizers, [code]Session[/code]) talks to Godot's
## high-level multiplayer API and never to a concrete peer class, so swapping
## ENet for a relay later (D4) means writing one new subclass of this and
## changing which one [code]Session[/code] instantiates.
##
## Subclasses must override [method host] and [method join].

## The [enum Error] from the most recent [method host] / [method join] call.
var last_error: Error = OK

## Start listening. [param max_clients] excludes the host itself.
## Returns a ready peer, or [code]null[/code] on failure ([member last_error] is set).
func host(_port: int, _max_clients: int) -> MultiplayerPeer:
	push_error("NetTransport.host() not implemented by %s" % get_script().resource_path)
	last_error = ERR_UNCONFIGURED
	return null

## Begin connecting to a host. The connection completes asynchronously through
## the [code]multiplayer.connected_to_server[/code] / [code]connection_failed[/code] signals.
## Returns a peer, or [code]null[/code] if the attempt could not even start.
func join(_address: String, _port: int) -> MultiplayerPeer:
	push_error("NetTransport.join() not implemented by %s" % get_script().resource_path)
	last_error = ERR_UNCONFIGURED
	return null
