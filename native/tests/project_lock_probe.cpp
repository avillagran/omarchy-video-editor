// Test-only native editor save attempt, synchronized by a parent process.
#include <QGuiApplication>
#include <QVariantMap>
#include <cstdio>
#include <cstring>
#include "../src/engine.h"

int main(int argc, char **argv) {
  QGuiApplication app(argc, argv);
  if ((argc != 2 && argc != 3) || qEnvironmentVariableIsEmpty("OMASHORT_DATA")
      || (argc == 3 && std::strcmp(argv[2], "--save-as") != 0)) return 2;
  OmareelEngine engine;
  QVariantMap doc = engine.openProjectFile(QString::fromLocal8Bit(argv[1]));
  if (doc.isEmpty()) return 3;
  std::puts("READY");
  std::fflush(stdout);
  if (std::getchar() == EOF) return 4;
  doc[QStringLiteral("template")] = QStringLiteral("pip");
  const bool saved = argc == 3 ? engine.saveProjectAs(QString::fromLocal8Bit(argv[1]), doc)
                                : engine.saveProject(doc);
  std::puts(saved ? "SAVED" : "REJECTED");
  return 0;
}
