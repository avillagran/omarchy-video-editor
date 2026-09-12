// Test-only observer: real engine + production QML, driven by an external editor.
#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickItem>
#include <QQuickWindow>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QSaveFile>
#include <QFile>
#include <QFileInfo>
#include <QDir>
#include <QTimer>
#include <QTest>
#include "../src/engine.h"

static void inspect(QQuickItem *item, QJsonArray &nodes, QString space = {}) {
  if (item->property("space").isValid()) space = item->property("space").toString();
  if (QString::fromLatin1(item->metaObject()->className()).startsWith("Timeline")) space = "timeline";
  const QVariant text = item->property("text");
  if (item->objectName() == "layerCard")
    nodes.append(QJsonObject{{"card", true}, {"visible", item->isVisible()},
      {"expanded", item->property("expanded").toBool()}, {"height", item->height()}});
  if (text.isValid() && !text.toString().isEmpty()) {
    const QPointF p = item->mapToScene(QPointF());
    nodes.append(QJsonObject{{"text", text.toString()}, {"space", space},
      {"visible", item->isVisible()}, {"x", p.x()}, {"y", p.y()},
      {"width", item->width()}, {"height", item->height()},
      {"color", item->property("color").toString()}});
  }
  for (auto *child : item->childItems()) inspect(child, nodes, space);
}
static QQuickItem *input(QQuickItem *item, const QString &text) {
  if (item->isVisible() && item->inherits("QQuickTextInput") && item->property("text").toString() == text) return item;
  for (auto *child : item->childItems()) if (auto *found = input(child, text)) return found;
  return nullptr;
}
static QQuickItem *named(QQuickItem *item, const QString &name) {
  if (item->isVisible() && item->objectName() == name) return item;
  for (auto *child : item->childItems()) if (auto *found = named(child, name)) return found;
  return nullptr;
}
static void writeJson(const QString &path, const QJsonObject &value) {
  QSaveFile file(path);
  if (file.open(QIODevice::WriteOnly)) { file.write(QJsonDocument(value).toJson()); file.commit(); }
}
int main(int argc, char **argv) {
  QGuiApplication::setApplicationName("omareel-live-reload-test");
  QGuiApplication app(argc, argv);
  if (argc != 2 || qEnvironmentVariableIsEmpty("OMAREEL_DATA")) return 2;
  OmareelEngine engine;
  QQmlApplicationEngine qml;
  qml.rootContext()->setContextProperty("engine", &engine);
  for (const auto *flag : {"uitest", "uitestBlocks", "uitestOut", "uitestPause", "uitestDock", "uitestRender"})
    qml.rootContext()->setContextProperty(flag, false);
  int reloads = 0;
  QObject::connect(&engine, &OmareelEngine::projectChangedExternally, &app, [&](const QVariantMap &) { ++reloads; });
  qml.load(QUrl::fromLocalFile(QFileInfo(argv[1]).absoluteFilePath()));
  if (qml.rootObjects().isEmpty()) return 3;
  auto *window = qobject_cast<QQuickWindow *>(qml.rootObjects().first());
  if (!window) return 4;
  window->resize(1728, 1117);
  if (QGuiApplication::platformName() == "wayland") window->showFullScreen();
  const QString data = engine.dataDir();
  QTimer timer;
  QObject::connect(&timer, &QTimer::timeout, &app, [&]() {
    QFile command(data + "/command.json");
    if (command.open(QIODevice::ReadOnly)) {
      const auto cmd = QJsonDocument::fromJson(command.readAll()).object();
      command.close(); command.remove();
      auto toggleLayer = [&]() {
        if (auto *toggle = named(window->contentItem(), "layerExpandToggle")) {
          const QPoint p = toggle->mapToScene(QPointF(toggle->width()/2, toggle->height()/2)).toPoint();
          QTest::mouseClick(window, Qt::LeftButton, Qt::NoModifier, p);
        }
      };
      if (cmd.contains("toggleLayer")) toggleLayer();
      if (cmd.contains("uiText")) {
        auto *field = input(window->contentItem(), cmd["oldText"].toString());
        if (!field) {
          toggleLayer();
          QCoreApplication::processEvents();
          field = input(window->contentItem(), cmd["oldText"].toString());
        }
        if (!field) { fprintf(stderr, "UI text field not found\n"); app.exit(5); return; }
        field->forceActiveFocus();
        QTest::keyClick(window, Qt::Key_A, Qt::ControlModifier);
        for (QChar ch : cmd["uiText"].toString())
          QTest::keyClick(window, Qt::Key(ch.toUpper().unicode()), ch.isUpper() ? Qt::ShiftModifier : Qt::NoModifier);
      }
      if (cmd.contains("screenshot"))
        window->grabWindow().save(data + "/" + QFileInfo(cmd["screenshot"].toString()).fileName());
    }
    QJsonArray nodes;
    inspect(window->contentItem(), nodes);
    writeJson(data + "/observed.json", {{"reloads", reloads}, {"nodes", nodes},
      {"trimIn", window->property("trimIn").toDouble()},
      {"trimOut", window->property("trimOut").toDouble()},
      {"focusText", window->activeFocusItem() ? window->activeFocusItem()->property("text").toString() : QString()}});
  });
  timer.start(100);
  QTimer::singleShot(90000, &app, &QCoreApplication::quit);
  return app.exec();
}
