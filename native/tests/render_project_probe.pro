QT += quick multimedia
CONFIG += c++17 console
CONFIG -= app_bundle
TARGET = render-project-probe
TEMPLATE = app
SOURCES += render_project_probe.cpp ../src/engine.cpp
HEADERS += ../src/engine.h
