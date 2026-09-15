// main.cpp - OmaShort Native entry point (Qt6 QML app, Wayland on Omarchy)
#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QFileInfo>
#include <QIcon>
#include <QEventLoop>
#include <QTimer>
#include <QDebug>
#include <QJsonDocument>
#include <QJsonObject>
#include <QDir>
#include <QFile>
#include <QImage>
#include <QProcess>
#include <QStandardPaths>
#include "engine.h"

// Headless pipeline check: scan -> cut -> render (completa) on the first video.
#define STLOG(...) do { fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); fflush(stderr); } while (0)
static int selftest(OmareelEngine &engine) {
  const QVariantList media = engine.scanMedia();
  STLOG("selftest: media files: %lld", static_cast<long long>(media.size()));
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
    QVariantMap layer; layer["type"] = "text"; layer["text"] = "OmaShort"; layer["x"] = 0.5; layer["y"] = 0.12;
    layer["size"] = 110; layer["color"] = "#ffffff"; layer["in"] = 0.0; layer["out"] = cutDur;
    QVariantList testLayers{layer};
    // Animated magenta marker: proves exported keyframe tween + alpha fades,
    // not merely the QML preview. The render assertions below inspect real frames.
    const QString markerPath = engine.dataDir() + QStringLiteral("/selftest-marker.png");
    QImage marker(96, 96, QImage::Format_ARGB32);
    marker.fill(QColor(QStringLiteral("#ff00ff")));
    marker.save(markerPath);
    QVariantMap moving{{"type", "image"}, {"path", markerPath},
                       {"x", 0.2}, {"y", 0.55}, {"w", 0.12}, {"h", 0.08},
                       {"inS", 0.0}, {"outS", cutDur}, {"fadeIn", 0.5}, {"fadeOut", 0.5}};
    moving["keyframes"] = QVariantList{
      QVariantMap{{"time", 0.0}, {"x", 0.2}, {"w", 0.05}, {"h", 0.04}, {"easing", "easeInOut"}},
      QVariantMap{{"time", cutDur}, {"x", 0.8}, {"w", 0.20}, {"h", 0.12}}
    };
    testLayers << moving;
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
  bool outputListed = false;
  for (const QVariant &item : engine.listOutputs())
    outputListed = outputListed || item.toMap().value(QStringLiteral("path")).toString() == outPath;
  if (!outputListed || !outPath.contains(QStringLiteral("/projects/"))) {
    STLOG("selftest: FAIL project output scope"); return 25;
  }

  const QVariantMap probe = engine.probeVideo(outPath);
  STLOG("selftest: out %dx%d dur %.1f", probe.value("width").toInt(), probe.value("height").toInt(), probe.value("duration").toDouble());
  const bool ok = probe.value("width").toInt() == 1080 && probe.value("height").toInt() == 1920;
  if (!ok) { STLOG("selftest: FAIL dimensions"); return 6; }

  auto markerStats = [&](double at) {
    const QString frame = engine.dataDir() + QStringLiteral("/selftest-frame-%1.png").arg(at, 0, 'f', 2);
    QProcess ff;
    ff.start(qEnvironmentVariable("FFMPEG_BIN", QStringLiteral("ffmpeg")),
             {"-v", "error", "-y", "-ss", QString::number(at), "-i", outPath,
              "-frames:v", "1", frame});
    ff.waitForFinished(30000);
    QImage img(frame);
    qint64 sumX = 0; int count = 0;
    for (int y = 0; y < img.height(); y += 2) for (int x = 0; x < img.width(); x += 2) {
      const QColor c = img.pixelColor(x, y);
      if (c.red() > 180 && c.blue() > 180 && c.green() < 90) { sumX += x; count++; }
    }
    return QPair<double,int>(count ? (double)sumX / count : -1.0, count);
  };
  const auto early = markerStats(0.05), middle = markerStats(cutDur / 2);
  const auto moved = markerStats(cutDur - 1.0), late = markerStats(cutDur - 0.05);
  STLOG("selftest: marker early=(%.1f,%d) middle=(%.1f,%d) moved=(%.1f,%d) late=(%.1f,%d)",
        early.first, early.second, middle.first, middle.second, moved.first, moved.second, late.first, late.second);
  if (!(middle.first > 450 && middle.first < 630 && moved.first > middle.first + 180)) {
    STLOG("selftest: FAIL exported keyframe tween"); return 9;
  }
  if (!(moved.second > middle.second * 1.5)) {
    STLOG("selftest: FAIL exported keyframe size tween"); return 11;
  }
  if (!(early.second < middle.second / 3 && late.second < middle.second / 3)) {
    STLOG("selftest: FAIL exported layer fades"); return 10;
  }

  // Named project persistence: save atomically, switch active project, then load it.
  const QString project = engine.dataDir() + QStringLiteral("/selftest-project.json");
  const QVariantMap projectDoc{{"version", 1}, {"app", "omashort"},
                               {"layers", QVariantList{QVariantMap{{"type", "text"}, {"text", "Saved project"}}}}};
  if (!engine.saveProjectAs(project, projectDoc)) { STLOG("selftest: FAIL project save"); return 7; }
  const QVariantMap loaded = engine.openProjectFile(project);
  if (loaded.value("version").toInt() != 1 || loaded.value("layers").toList().size() != 1) {
    STLOG("selftest: FAIL project load"); return 8;
  }
  const QString portableDir = engine.dataDir() + QStringLiteral("/portable");
  QDir().mkpath(portableDir + QStringLiteral("/assets"));
  const QString portablePath = portableDir + QStringLiteral("/demo.json");
  QFile portableFile(portablePath);
  const QVariantMap portableDoc{{"version", 1}, {"video", "assets/source.mp4"},
    {"layers", QVariantList{QVariantMap{{"type", "image"}, {"path", "assets/overlay.png"}}}}};
  if (!portableFile.open(QIODevice::WriteOnly)
      || portableFile.write(QJsonDocument::fromVariant(portableDoc).toJson()) < 1) {
    STLOG("selftest: FAIL portable project fixture"); return 12;
  }
  portableFile.close();
  const QVariantMap portable = engine.openProjectFile(portablePath);
  const QString expectedVideo = portableDir + QStringLiteral("/assets/source.mp4");
  const QString expectedOverlay = portableDir + QStringLiteral("/assets/overlay.png");
  const QVariantMap pathHints = portable.value("_pathHints").toMap();
  if (portable.value("video").toString() != expectedVideo
      || portable.value("layers").toList().first().toMap().value("path").toString() != expectedOverlay
      || pathHints.value(expectedVideo).toString() != QStringLiteral("assets/source.mp4")
      || pathHints.value(expectedOverlay).toString() != QStringLiteral("assets/overlay.png")) {
    STLOG("selftest: FAIL relative project paths"); return 13;
  }
  const QString portableCopyDir = engine.dataDir() + QStringLiteral("/portable-copy");
  const QString portableCopyPath = portableCopyDir + QStringLiteral("/demo-copy.json");
  QDir().mkpath(portableCopyDir);
  if (!engine.saveProjectAs(portableCopyPath, portable)) {
    STLOG("selftest: FAIL portable Save As"); return 18;
  }
  QFile portableCopy(portableCopyPath);
  if (!portableCopy.open(QIODevice::ReadOnly)) return 18;
  const QVariantMap savedPortable = QJsonDocument::fromJson(portableCopy.readAll()).object().toVariantMap();
  if (savedPortable.value("video").toString() != QStringLiteral("../portable/assets/source.mp4")
      || savedPortable.value("layers").toList().first().toMap().value("path").toString()
           != QStringLiteral("../portable/assets/overlay.png")
      || savedPortable.contains("_pathHints")) {
    STLOG("selftest: FAIL portable Save As paths"); return 18;
  }
  const QString activeProject = engine.projectPath();
  if (engine.saveProjectAs(QStringLiteral("/proc/omashort-write-must-fail.json"), portable)
      || engine.projectPath() != activeProject) {
    STLOG("selftest: FAIL Save As write-error reporting"); return 19;
  }
  const QString freshProject = engine.newProject();
  const QString secondFreshProject = engine.newProject();
  const QString thirdFreshProject = engine.newProject();
  if (freshProject.isEmpty() || freshProject == activeProject
      || secondFreshProject.isEmpty() || secondFreshProject == freshProject
      || thirdFreshProject.isEmpty() || thirdFreshProject == freshProject
      || thirdFreshProject == secondFreshProject
      || QFileInfo::exists(freshProject) || QFileInfo::exists(secondFreshProject)
      || QFileInfo::exists(thirdFreshProject)) {
    STLOG("selftest: FAIL new project target isolation"); return 20;
  }
  if (!engine.listOutputs().isEmpty()) {
    STLOG("selftest: FAIL new project inherited outputs"); return 26;
  }
  const QString sourcePath = first.value(QStringLiteral("path")).toString();
  if (!engine.removeSource(sourcePath) || !QFileInfo::exists(sourcePath)) {
    STLOG("selftest: FAIL remove source kept file"); return 21;
  }
  for (const QVariant &item : engine.scanMedia()) {
    if (item.toMap().value(QStringLiteral("path")).toString() == sourcePath) {
      STLOG("selftest: FAIL removed source still listed"); return 22;
    }
  }
  if (engine.importVideo(QUrl::fromLocalFile(sourcePath).toString()) != sourcePath) {
    STLOG("selftest: FAIL reimport source"); return 23;
  }
  bool sourceRestored = false;
  for (const QVariant &item : engine.scanMedia())
    sourceRestored = sourceRestored
        || item.toMap().value(QStringLiteral("path")).toString() == sourcePath;
  if (!sourceRestored) { STLOG("selftest: FAIL reimport source listing"); return 24; }

  const QString collisionA = engine.dataDir() + QStringLiteral("/collision-a/shared.mp4");
  const QString collisionB = engine.dataDir() + QStringLiteral("/collision-b/shared.mp4");
  QDir().mkpath(QFileInfo(collisionA).absolutePath());
  QDir().mkpath(QFileInfo(collisionB).absolutePath());
  QFile::copy(sourcePath, collisionA);
  QFile::copy(sourcePath, collisionB);
  const QString importedA = engine.importVideo(QUrl::fromLocalFile(collisionA).toString());
  const QString importedB = engine.importVideo(QUrl::fromLocalFile(collisionB).toString());
  if (importedA.isEmpty() || importedB.isEmpty() || importedA == importedB
      || !QFileInfo::exists(importedA) || !QFileInfo::exists(importedB)) {
    STLOG("selftest: FAIL same-basename imports"); return 27;
  }

  // Exercise the asynchronous ASR process contract without a model download.
  const QString fakeModel = engine.dataDir() + QStringLiteral("/fake-asr-model");
  const QString fakeScript = engine.dataDir() + QStringLiteral("/fake-asr.py");
  QDir().mkpath(fakeModel);
  QFile scriptFile(fakeScript);
  if (!scriptFile.open(QIODevice::WriteOnly | QIODevice::Truncate)) return 14;
  scriptFile.write("import pathlib,sys\npathlib.Path(sys.argv[3]).write_text('1\\n00:00:00,000 --> 00:00:01,000\\nOffline ASR\\n\\n')\n");
  scriptFile.close();
  qputenv("OMASHORT_ASR_PYTHON", QStandardPaths::findExecutable(QStringLiteral("python3")).toLocal8Bit());
  qputenv("OMASHORT_ASR_MODEL", fakeModel.toLocal8Bit());
  qputenv("OMASHORT_ASR_SCRIPT", fakeScript.toLocal8Bit());
  QString srtPath;
  {
    QEventLoop loop;
    QTimer watchdog; watchdog.setSingleShot(true); watchdog.start(30000);
    QObject::connect(&watchdog, &QTimer::timeout, &loop, &QEventLoop::quit);
    QObject::connect(&engine, &OmareelEngine::subtitlesReady, &loop,
                     [&](const QString &path) { srtPath = path; loop.quit(); });
    engine.transcribeAudio(cutPath, QStringLiteral("es"));
    loop.exec();
  }
  const QVariantList subtitleLayers = engine.subtitleLayers(srtPath, true);
  if (srtPath.isEmpty() || subtitleLayers.size() != 1
      || subtitleLayers.first().toMap().value("text").toString() != QLatin1String("Offline ASR")) {
    STLOG("selftest: FAIL offline ASR process contract"); return 15;
  }
  STLOG("selftest: PASS");
  return 0;
}

int main(int argc, char *argv[]) {
  QGuiApplication::setApplicationName(QStringLiteral("omashort"));
  QGuiApplication::setApplicationDisplayName(QStringLiteral("OmaShort"));
  QGuiApplication app(argc, argv);

  OmareelEngine engine;
  if (app.arguments().contains(QStringLiteral("--theme-probe"))) {
    auto reportTheme = [&engine]() {
      fprintf(stdout, "THEME %s\n", QJsonDocument::fromVariant(engine.theme()).toJson(QJsonDocument::Compact).constData());
      fflush(stdout);
    };
    QObject::connect(&engine, &OmareelEngine::themeChanged, &app, reportTheme);
    reportTheme();
    QTimer::singleShot(7000, &app, &QCoreApplication::quit);
    return app.exec();
  }
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

  // Prefer a mutable deployed QML tree, then a source checkout, then the
  // embedded resource used by installed and standalone binaries.
  const QString installed = engine.dataDir() + QStringLiteral("/native-qml/main.qml");
  const QString sourceTree = QStringLiteral("qml/main.qml");
  const QUrl url = QFileInfo::exists(installed)
      ? QUrl::fromLocalFile(installed)
      : (QFileInfo::exists(sourceTree) ? QUrl::fromLocalFile(sourceTree)
                                      : QUrl(QStringLiteral("qrc:/qml/main.qml")));
  QObject::connect(&qmlEngine, &QQmlApplicationEngine::objectCreationFailed,
                   &app, []() { QCoreApplication::exit(-1); }, Qt::QueuedConnection);
  qmlEngine.load(url);
  return app.exec();
}
