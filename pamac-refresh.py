#! /usr/bin/python3
# -*- coding:utf-8 -*-

from gi.repository import GObject
from pamac import common
import dbus

def reply(reply):
	transaction.StopDaemon()
	print('check updates done')
	loop.quit()

def error(error):
	transaction.StopDaemon()
	print('check updates failed')
	loop.quit()

loop = GObject.MainLoop()

if not common.pid_file_exists():
	print('checking updates')
	from pamac import transaction
	bus = dbus.SystemBus()
	bus.add_signal_receiver(reply, dbus_interface = "org.manjaro.pamac", signal_name = "EmitTransactionDone")
	bus.add_signal_receiver(error, dbus_interface = "org.manjaro.pamac", signal_name = "EmitTransactionError")
	transaction.Refresh()
	loop.run()
