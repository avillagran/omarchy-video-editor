// engine.h - Omareel Native backend: local video library, cut, vertical render
// with text/subtitle overlays. ffmpeg/ffprobe via QProcess on a worker thread.
#ifndef OMAREEL_ENGINE_H
#define OMAREEL_ENGINE_H

#include <QObject>
#include <QVariantList>
#include <QVariantMap>
#include <QString>
#include <QThread>
#include <QProcess>
#include <QQueue>
#include <QMutex>
#include <QWaitCondition>
#include <QFileSystemWatcher>
#include <QHash>

struct EngineTask {
  QString kind;              // "thumb" | "cut" | "render"
  QVariantMap params;
};

class EngineWorker : public QObject {
  Q_OBJECT
public:
  explicit EngineWorker(const QString &dataDir) : m_dataDir(dataDir) {}
  void killCurrent() { m_procMutex.lock(); if (m_current) m_current->kill(); m_procMutex.unlock(); }
public slots:
  void process();
signals:
  void thumbReady(const QString &videoPath, const QString &thumbUrl);
  void stripReady(const QString &videoPath, const QStringList &urls);
  void cutDone(const QString &clipId, const QString &clipPath, double duration);
  void renderProgress(const QString &jobId, double pct);
  void renderDone(const QString &jobId, const QString &outPath);
  void taskError(const QString &jobId, const QString &message);
public:
  QMutex mutex;
  QWaitCondition cond;
  QQueue<EngineTask> queue;
  bool abort = false;
  QMutex m_procMutex;
  QProcess *m_current = nullptr;
private:
  QString m_dataDir;
};

class OmareelEngine : public QObject {
  Q_OBJECT
  Q_PROPERTY(QString dataDir READ dataDir CONSTANT)
  Q_PROPERTY(QString language READ language WRITE setLanguage NOTIFY languageChanged)
public:
  explicit OmareelEngine(QObject *parent = nullptr);
  ~OmareelEngine() override;

  QString dataDir() const { return m_dataDir; }
  QString language() const { return m_lang; }
  void setLanguage(const QString &l);

  // Library
  Q_INVOKABLE QVariantList scanMedia();                 // sync, fast (ffprobe per file)
  Q_INVOKABLE QVariantMap probeVideo(const QString &path);
  Q_INVOKABLE void requestThumb(const QString &videoPath);
  Q_INVOKABLE QString cachedThumb(const QString &videoPath);
  Q_INVOKABLE void requestStrip(const QString &videoPath, int frames = 16);   // filmstrip for the timeline
  Q_INVOKABLE QStringList cachedStrip(const QString &videoPath);
  Q_INVOKABLE QString importVideo(const QString &fileUrl);   // copy/link into media/
  Q_INVOKABLE void deleteMedia(const QString &path);
  Q_INVOKABLE QVariantList listOutputs();
  Q_INVOKABLE void openFolder(const QString &path);

  // Pipeline
  Q_INVOKABLE void cut(const QString &sessionPath, double start, double end);
  Q_INVOKABLE void renderVertical(const QVariantMap &params);
  // params: clipPath, template ("completa"|"apilar"), regions {main:{x,y,w,h}} or
  // {top:{...}, bottom:{...}, split}, layers [ {text,x,y,size,color,font,in,out} ],
  // srtPath ("" = none), all region coords in PERCENT of source (0-100).

  // Rasterize a text layer to a transparent 1080x1920 PNG (also used by QML preview)
  Q_INVOKABLE QString rasterizeText(const QVariantMap &layer);

  // Project file (simple JSON, AI-editable; external edits reload live)
  Q_INVOKABLE QString projectPath() const { return m_dataDir + QStringLiteral("/project.json"); }
  Q_INVOKABLE QVariantMap loadProject();                 // read project.json ({} if none)
  Q_INVOKABLE void saveProject(const QVariantMap &doc);  // write + remember hash (watcher ignores self)

signals:
  void languageChanged();
  void thumbReady(const QString &videoPath, const QString &thumbUrl);
  void stripReady(const QString &videoPath, const QStringList &urls);
  void cutDone(const QString &clipId, const QString &clipPath, double duration);
  void renderProgress(const QString &jobId, double pct);
  void renderDone(const QString &jobId, const QString &outPath);
  void taskError(const QString &jobId, const QString &message);
  void projectChangedExternally(const QVariantMap &doc);

private:
  void enqueue(const EngineTask &t);
  QString m_dataDir;
  QString m_lang = QStringLiteral("es");
  QThread m_thread;
  EngineWorker *m_worker;
  QFileSystemWatcher m_projWatcher;
  QHash<QString, QVariantMap> m_probeCache;
  QByteArray m_lastProjHash;
};

#endif
