// Headless renderer for a real OmaShort project JSON.
#include <QGuiApplication>
#include <QEventLoop>
#include <QJsonDocument>
#include <QTimer>
#include <cstdio>
#include "../src/engine.h"

int main(int argc, char **argv) {
  QGuiApplication app(argc, argv);
  bool horizontal = false;
  bool highQuality = false;
  if (argc < 2 || argc > 4) {
    std::fprintf(stderr, "usage: render-project-probe PROJECT.json [--horizontal] [--high-quality]\n");
    return 2;
  }
  for (int i = 2; i < argc; ++i) {
    const QString arg = QString::fromLocal8Bit(argv[i]);
    if (arg == QLatin1String("--horizontal")) horizontal = true;
    else if (arg == QLatin1String("--high-quality")) highQuality = true;
    else {
      std::fprintf(stderr, "unknown option: %s\n", argv[i]);
      return 2;
    }
  }
  OmareelEngine engine;
  const QVariantMap doc = engine.openProjectFile(QString::fromLocal8Bit(argv[1]));
  const QString video = doc.value("video").toString();
  if (doc.value("version").toInt() < 1 || video.isEmpty()) {
    std::fprintf(stderr, "invalid project\n");
    return 3;
  }

  QVariantList segments;
  for (const QVariant &value : doc.value("blocks").toList()) {
    const QVariantMap block = value.toMap();
    if (!block.value("visible", true).toBool()) continue;
    const QString layout = block.value("layout", "completa").toString();
    QVariantMap regions = block.value("regions").toMap();
    if (layout == QLatin1String("apilar")) regions["split"] = block.value("split", 0.5);
    if (layout == QLatin1String("pip") || layout == QLatin1String("circulo")) {
      regions["fx"] = block.value("fx", 0.5);
      regions["fy"] = block.value("fy", 0.72);
    }
    segments << QVariantMap{{"start", block.value("start")}, {"end", block.value("end")},
                            {"layout", layout}, {"regions", regions}};
  }
  if (segments.isEmpty()) {
    QVariantMap regions{{"main", doc.value("region")}};
    const QString layout = doc.value("template", "completa").toString();
    if (layout == QLatin1String("apilar")) {
      const QVariantMap apilar = doc.value("apilar").toMap();
      regions = {{"top", apilar.value("top")}, {"bottom", apilar.value("bottom")},
                 {"split", apilar.value("split", 0.5)}};
    }
    segments << QVariantMap{{"start", doc.value("trim").toMap().value("in", 0)},
                            {"end", doc.value("trim").toMap().value("out", 10)},
                            {"layout", layout}, {"regions", regions}};
  }

  QString output, error;
  QEventLoop loop;
  QTimer timeout;
  timeout.setSingleShot(true);
  timeout.start(300000);
  QObject::connect(&timeout, &QTimer::timeout, &loop, [&] { error = "timeout"; loop.quit(); });
  QObject::connect(&engine, &OmareelEngine::renderProgress, [](const QString &, double value) {
    std::fprintf(stderr, "render %.0f%%\n", value * 100);
  });
  QObject::connect(&engine, &OmareelEngine::renderDone, &loop,
                   [&](const QString &, const QString &path) { output = path; loop.quit(); });
  QObject::connect(&engine, &OmareelEngine::taskError, &loop,
                   [&](const QString &, const QString &message) { error = message; loop.quit(); });
  engine.renderVertical({{"clipPath", video}, {"template", doc.value("template", "completa")},
                         {"regions", QVariantMap{{"main", doc.value("region")}}},
                         {"layers", doc.value("layers")}, {"segments", segments},
                         {"srtPath", doc.value("srt")}, {"width", horizontal ? 1920 : 1080},
                         {"height", horizontal ? 1080 : 1920},
                         {"space", horizontal ? "prog" : "out"},
                         {"suffix", horizontal ? "-horizontal-probe" : "-preview"},
                         {"codec", "h264"}, {"crf", highQuality ? 12 : 18},
                         {"preset", highQuality ? "slow" : "veryfast"}});
  loop.exec();
  if (output.isEmpty()) {
    std::fprintf(stderr, "render failed: %s\n", error.toLocal8Bit().constData());
    return 4;
  }
  std::printf("%s\n", output.toLocal8Bit().constData());
  return 0;
}
