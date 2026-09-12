QT += quick multimedia
CONFIG += c++17
TARGET = omareel-native
TEMPLATE = app
SOURCES += src/main.cpp src/engine.cpp
HEADERS += src/engine.h
RESOURCES += qml.qrc

isEmpty(PREFIX): PREFIX = /usr/local
target.path = $$PREFIX/bin
asr.path = $$PREFIX/bin/scripts
asr.files = scripts/transcribe_local.py
INSTALLS += target asr

unix {
    # Keep source and shadow builds behavior-identical without requiring install.
    QMAKE_POST_LINK += $$QMAKE_MKDIR $$shell_quote($$OUT_PWD/scripts) && $$QMAKE_COPY $$shell_quote($$PWD/scripts/transcribe_local.py) $$shell_quote($$OUT_PWD/scripts/transcribe_local.py)
}
