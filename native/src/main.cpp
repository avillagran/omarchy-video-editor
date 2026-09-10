// main.cpp - Omareel Native entry point (Qt6 QML app, Wayland on Omarchy)
#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QFileInfo>
#include <QIcon>
#include <QEventLoop>
#include <QTimer>
#include <QDebug>
#include "engine.h"

// Headless pipeline check: scan -> cut -> render (completa) on the first video.
#define STLOG(...) do { fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); fflush(stderr); } while (0)
static int selftest(OmareelEngine &engine) {
  const QVariantList media = engine.scanMedia();
  STLOG("selftest: media files: %d", media.size());
  if (media.isEmpty()) { STLOG("selftest: FAIL no media"); return 2; }
  const QVariantMap first = media.first().toMap();
  STLOG("selftest: first: %s dur %.1f", first.value("id").toString().toLocal8Bit().constData(), first.value("duration").toDouble());

  QString cutPath; double cutDur = 0; QString errMsg;
  {
    QEventLoop loop;
    QTimer watchdog; watchdog.setSingleShot(true); watchdog.start(120000);
    QObject::connect(&watchdog, &QTimer::timeout, &loop, [&]() { errMsg = "timeout"; loop.quit(); });
    QObject::connect(&engine, &OmareelEngine::cutDone, &loop, [&](const QString &, const QString &p, double d) {
      STLOG("selftest: cut done -> %s", p.toLocal8Bit().constData()); cutPath = p; cutDur = d; loop.quit();
    });
    QObject::connect(&engine, &OmareelEngine::taskError, &loop, [&](const QString &, const QString &m) {
      errMsg = m; loop.quit();
    });
    engine.cut(first.value("path").toString(), 1.0, 6.0);
    loop.exec();
  }
  if (cutPath.isEmpty()) { STLOG("selftest: FAIL cut: %s", errMsg.toLocal8Bit().constData()); return 4; }

  QString outPath; errMsg.clear();
  {
    QEventLoop loop;
    QTimer watchdog; watchdog.setSingleShot(true); watchdog.start(120000);
    QObject::connect(&watchdog, &QTimer::timeout, &loop, [&]() { errMsg = "timeout"; loop.quit(); });
    QObject::connect(&engine, &OmareelEngine::renderDone, &loop, [&](const QString &, const QString &p) {
      STLOG("selftest: render done -> %s", p.toLocal8Bit().constData()); outPath = p; loop.quit();
    });
    QObject::connect(&engine, &OmareelEngine::renderProgress, &loop, [](const QString &, double pct) {
      STLOG("selftest: render %.0f%%", pct * 100);
    });
    QObject::connect(&engine, &OmareelEngine::taskError, &loop, [&](const QString &, const QString &m) {
      errMsg = m; loop.quit();
    });
    QVariantMap mainRegion; mainRegion["x"] = 0; mainRegion["y"] = 0; mainRegion["w"] = 100; mainRegion["h"] = 100;
    QVariantMap regions; regions["main"] = mainRegion;
    QVariantMap layer; layer["type"] = "text"; layer["text"] = "Omareel"; layer["x"] = 0.5; layer["y"] = 0.12;
    layer["size"] = 110; layer["color"] = "#ffffff"; layer["in"] = 0.0; layer["out"] = cutDur;
    QVariantList testLayers{layer};
    // optional gif layer when /tmp/test.gif exists
    if (QFileInfo::exists("/tmp/test.gif")) {
      QVariantMap g; g["type"] = "gif"; g["path"] = "/tmp/test.gif";
      g["x"] = 0.5; g["y"] = 0.7; g["w"] = 0.3; g["h"] = 0.17; g["in"] = 0.0; g["out"] = cutDur;
      testLayers << g;
      STLOG("selftest: incluyendo capa gif");
    }
    // video PiP layer with circle mask (uses the source itself as the layer video)
    {
      QVariantMap v; v["type"] = "video"; v["path"] = first.value("path").toString(); v["shape"] = "circle";
      v["x"] = 0.5; v["y"] = 0.72; v["w"] = 0.4; v["h"] = 0.23; v["in"] = 0.0; v["out"] = cutDur;
      testLayers << v;
      STLOG("selftest: incluyendo capa video circle");
    }
    // blocks: 4 segments, one per layout (completa, apilar, pip, circulo)
    const QVariantMap full = QVariantMap{{"x",0},{"y",0},{"w",100},{"h",100}};
    const QVariantMap center = QVariantMap{{"x",25},{"y",25},{"w",50},{"h",50}};
    const double q = cutDur / 4;
    QVariantList segs;
    segs << QVariantMap{{"start",0.0},{"end",q},{"layout","completa"},{"regions",QVariantMap{{"main",full}}}}
         << QVariantMap{{"start",q},{"end",2*q},{"layout","apilar"},{"regions",QVariantMap{{"top",full},{"bottom",center},{"split",0.5}}}}
         << QVariantMap{{"start",2*q},{"end",3*q},{"layout","pip"},{"regions",QVariantMap{{"main",full},{"fg",center}}}}
         << QVariantMap{{"start",3*q},{"end",4*q},{"layout","circulo"},{"regions",QVariantMap{{"main",full},{"fg",center},{"fx",0.5},{"fy",0.72}}}};
    engine.renderVertical(QVariantMap{
      {"clipPath", cutPath}, {"template", "completa"}, {"regions", regions},
      {"layers", testLayers}, {"srtPath", ""}, {"segments", segs},
    });
    loop.exec();
  }
  if (outPath.isEmpty()) { STLOG("selftest: FAIL render: %s", errMsg.toLocal8Bit().constData()); return 5; }

  const QVariantMap probe = engine.probeVideo(outPath);
  STLOG("selftest: out %dx%d dur %.1f", probe.value("width").toInt(), probe.value("height").toInt(), probe.value("duration").toDouble());
  const bool ok = probe.value("width").toInt() == 1080 && probe.value("height").toInt() == 1920;
  STLOG("%s", ok ? "selftest: PASS" : "selftest: FAIL dimensions");
  return ok ? 0 : 6;
}

int main(int argc, char *argv[]) {
  QGuiApplication::setApplicationName(QStringLiteral("omareel"));
  QGuiApplication::setApplicationDisplayName(QStringLiteral("Omareel"));
  QGuiApplication app(argc, argv);

  OmareelEngine engine;
  if (app.arguments().contains(QStringLiteral("--selftest"))) {
    const int rc = selftest(engine);
    fflush(stdout); fflush(stderr);
    return rc;
  }

  QQmlApplicationEngine qmlEngine;
  qmlEngine.rootContext()->setContextProperty(QStringLiteral("engine"), &engine);
  // --uitest: deterministic UI state for screenshot verification
  // (trim 5-10 s, loop on, 2 text layers, play)
  qmlEngine.rootContext()->setContextProperty(QStringLiteral("uitestBlocks"),
      app.arguments().contains(QStringLiteral("--uitest-blocks")));
  qmlEngine.rootContext()->setContextProperty(QStringLiteral("uitest"),
      app.arguments().contains(QStringLiteral("--uitest")) || app.arguments().contains(QStringLiteral("--uitest-out"))
      || app.arguments().contains(QStringLiteral("--uitest-dock")) || app.arguments().contains(QStringLiteral("--uitest-blocks"))
      || app.arguments().contains(QStringLiteral("--uitest-pause")) || app.arguments().contains(QStringLiteral("--uitest-render")));
  qmlEngine.rootContext()->setContextProperty(QStringLiteral("uitestPause"),
      app.arguments().contains(QStringLiteral("--uitest-pause")));
  qmlEngine.rootContext()->setContextProperty(QStringLiteral("uitestOut"),
      app.arguments().contains(QStringLiteral("--uitest-out")));
  qmlEngine.rootContext()->setContextProperty(QStringLiteral("uitestDock"),
      app.arguments().contains(QStringLiteral("--uitest-dock")));
  qmlEngine.rootContext()->setContextProperty(QStringLiteral("uitestRender"),
      app.arguments().contains(QStringLiteral("--uitest-render")));

  // QML lives in <dataDir>/native-qml (installed) or ../qml relative to CWD (dev)
  const QString installed = engine.dataDir() + QStringLiteral("/native-qml/main.qml");
  const QUrl url = QFileInfo::exists(installed)
      ? QUrl::fromLocalFile(installed)
      : QUrl::fromLocalFile(QStringLiteral("qml/main.qml"));
  QObject::connect(&qmlEngine, &QQmlApplicationEngine::objectCreationFailed,
                   &app, []() { QCoreApplication::exit(-1); }, Qt::QueuedConnection);
  qmlEngine.load(url);
  return app.exec();
}
