QT += quick multimedia testlib
CONFIG += c++17 console
TEMPLATE = app
TARGET = live-reload-probe
SOURCES += live_reload_probe.cpp ../src/engine.cpp
HEADERS += ../src/engine.h
