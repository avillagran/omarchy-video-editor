// engine.cpp - Omareel Native backend implementation.
#include "engine.h"
#include <QDir>
#include <QFileInfo>
#include <QProcess>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QUuid>
#include <QStandardPaths>
#include <QDateTime>
#include <QImage>
#include <QPainter>
#include <QFont>
#include <QFontMetrics>
#include <QDesktopServices>
#include <QCryptographicHash>
#include <QUrl>
#include <QSaveFile>
#include <QRegularExpression>
#include <QDebug>
#include <QLocale>
#include <QCoreApplication>
#include <algorithm>

#ifdef Q_OS_ANDROID
#include <QJniObject>
#include <QtCore/qcoreapplication_platform.h>
#endif

static QString ffprobeBin() { return QStringLiteral("ffprobe"); }
static QString ffmpegBin() { return QStringLiteral("ffmpeg"); }

static QByteArray runProc(const QString &prog, const QStringList &args, int timeoutMs = 30000) {
  QProcess p;
  p.start(prog, args);
  p.closeWriteChannel();
  if (!p.waitForFinished(timeoutMs)) { p.kill(); p.waitForFinished(2000); return {}; }
  return p.readAllStandardOutput();
}

static QJsonObject probeJson(const QString &file, const QString &entries) {
  QByteArray out = runProc(ffprobeBin(), {QStringLiteral("-v"), QStringLiteral("error"),
    QStringLiteral("-show_entries"), entries, QStringLiteral("-of"), QStringLiteral("json"), file});
  return QJsonDocument::fromJson(out).object();
}

static double probeDuration(const QString &file) {
  return probeJson(file, QStringLiteral("format=duration"))
      .value(QStringLiteral("format")).toObject().value(QStringLiteral("duration")).toString().toDouble();
}

static int probeFps(const QString &file) {
  QString r = probeJson(file, QStringLiteral("stream=r_frame_rate"))
      .value(QStringLiteral("streams")).toArray().first().toObject()
      .value(QStringLiteral("r_frame_rate")).toString();
  QStringList parts = r.split(QLatin1Char('/'));
  double fps = parts.size() == 2 ? parts[0].toDouble() / qMax(1.0, parts[1].toDouble()) : r.toDouble();
  return fps > 0 ? qRound(fps) : 60;
}

static QVariantMap resolveProjectPaths(QVariantMap doc, const QString &projectFile);

/* ----------------------------- worker ----------------------------- */

// region map (percent) -> pixel rect string parts
static QString cropChain(const QVariantMap &pct, int srcW, int srcH, int outW, int outH) {
  double x = pct.value(QStringLiteral("x")).toDouble() / 100.0 * srcW;
  double y = pct.value(QStringLiteral("y")).toDouble() / 100.0 * srcH;
  double w = pct.value(QStringLiteral("w")).toDouble() / 100.0 * srcW;
  double h = pct.value(QStringLiteral("h")).toDouble() / 100.0 * srcH;
  if (w < 2) w = srcW;
  if (h < 2) h = srcH;
  return QStringLiteral("crop=%1:%2:%3:%4,scale=%5:%6:force_original_aspect_ratio=increase:flags=lanczos,crop=%5:%6")
      .arg((int)w).arg((int)h).arg((int)x).arg((int)y).arg(outW).arg(outH);
}

static QString num(double value) {
  return QLocale::c().toString(value, 'g', 12);
}

static QString easingExpression(const QString &name, const QString &p) {
  if (name == QLatin1String("easeIn")) return QStringLiteral("(%1)*(%1)").arg(p);
  if (name == QLatin1String("easeOut")) return QStringLiteral("1-(1-(%1))*(1-(%1))").arg(p);
  if (name == QLatin1String("easeInOut"))
    return QStringLiteral("if(lt((%1),0.5),2*(%1)*(%1),1-pow(-2*(%1)+2,2)/2)").arg(p);
  if (name == QLatin1String("backOut"))
    return QStringLiteral("1+2.70158*pow((%1)-1,3)+1.70158*pow((%1)-1,2)").arg(p);
  if (name == QLatin1String("bounce")) {
    const QString a = QStringLiteral("(%1)").arg(p);
    return QStringLiteral("if(lt(%1,1/2.75),7.5625*%1*%1,if(lt(%1,2/2.75),7.5625*(%1-1.5/2.75)*(%1-1.5/2.75)+0.75,if(lt(%1,2.5/2.75),7.5625*(%1-2.25/2.75)*(%1-2.25/2.75)+0.9375,7.5625*(%1-2.625/2.75)*(%1-2.625/2.75)+0.984375)))").arg(a);
  }
  return p;
}

static QVariantList sortedKeyframes(const QVariantMap &layer) {
  QVariantList frames;
  for (const QVariant &value : layer.value(QStringLiteral("keyframes")).toList()) {
    const QVariantMap frame = value.toMap();
    if (frame.contains(QStringLiteral("time"))) frames << frame;
  }
  std::stable_sort(frames.begin(), frames.end(), [](const QVariant &a, const QVariant &b) {
    return a.toMap().value(QStringLiteral("time")).toDouble()
         < b.toMap().value(QStringLiteral("time")).toDouble();
  });
  QVariantList unique;
  for (const QVariant &frame : frames) {
    if (!unique.isEmpty()
        && qAbs(unique.last().toMap().value(QStringLiteral("time")).toDouble()
                - frame.toMap().value(QStringLiteral("time")).toDouble()) < 0.000001)
      unique.last() = frame;
    else
      unique << frame;
  }
  return unique;
}

static QString animatedValue(const QVariantMap &layer, const QString &key, double fallback) {
  const double base = layer.value(key, fallback).toDouble();
  const QVariantList frames = sortedKeyframes(layer);
  if (frames.isEmpty()) return num(base);
  const QVariantMap first = frames.first().toMap();
  const double firstValue = first.value(key, base).toDouble();
  QString expression = num(frames.last().toMap().value(key, base).toDouble());
  for (int i = frames.size() - 2; i >= 0; --i) {
    const QVariantMap left = frames[i].toMap();
    const QVariantMap right = frames[i + 1].toMap();
    const double t0 = left.value(QStringLiteral("time")).toDouble();
    const double t1 = right.value(QStringLiteral("time")).toDouble();
    const double a = left.value(key, base).toDouble();
    const double b = right.contains(key) ? right.value(key).toDouble() : a;
    const QString p = QStringLiteral("max(0,min(1,(t-%1)/%2))").arg(num(t0), num(qMax(0.000001, t1 - t0)));
    const QString eased = easingExpression(left.value(QStringLiteral("easing"), QStringLiteral("linear")).toString(), p);
    const QString tween = QStringLiteral("%1+(%2-%1)*(%3)").arg(num(a), num(b), eased);
    expression = QStringLiteral("if(lte(t,%1),%2,%3)").arg(num(t1), tween, expression);
  }
  return QStringLiteral("if(lt(t,%1),%2,%3)")
      .arg(num(first.value(QStringLiteral("time")).toDouble()), num(firstValue), expression);
}

static QString animatedLayerValue(const QVariantMap &layer, bool progSpace,
                                  const QString &programKey, const QString &outputKey,
                                  double fallback) {
  const QString outputExpr = animatedValue(layer, outputKey, fallback);
  if (!progSpace) return outputExpr;

  // A base PROGRAM value is always present in Keyframes.at(), so normal sparse
  // interpolation against that base exactly matches the QML accessor.
  if (layer.contains(programKey))
    return animatedValue(layer, programKey, layer.value(outputKey, fallback).toDouble());

  // Without a base p* value, QML falls back to the evaluated OUTPUT property
  // for every interval whose left keyframe lacks p*. A later isolated p*
  // keyframe must not make the whole earlier animation use PROGRAM space.
  const QVariantList frames = sortedKeyframes(layer);
  if (frames.isEmpty()) return outputExpr;
  const QVariantMap first = frames.first().toMap();
  const QVariantMap last = frames.last().toMap();
  QString expression = last.contains(programKey) ? num(last.value(programKey).toDouble()) : outputExpr;
  for (int i = frames.size() - 2; i >= 0; --i) {
    const QVariantMap left = frames[i].toMap();
    const QVariantMap right = frames[i + 1].toMap();
    QString interval = outputExpr;
    if (left.contains(programKey)) {
      const double a = left.value(programKey).toDouble();
      const double b = right.contains(programKey) ? right.value(programKey).toDouble() : a;
      const double t0 = left.value(QStringLiteral("time")).toDouble();
      const double t1 = right.value(QStringLiteral("time")).toDouble();
      const QString p = QStringLiteral("max(0,min(1,(t-%1)/%2))").arg(num(t0), num(qMax(0.000001, t1 - t0)));
      interval = QStringLiteral("%1+(%2-%1)*(%3)")
                     .arg(num(a), num(b), easingExpression(left.value(QStringLiteral("easing"), QStringLiteral("linear")).toString(), p));
    }
    // At an interior boundary QML switches to a newly introduced p* value, but
    // retains a left p* when the right omits it. At the final keyframe QML's
    // endpoint clamp instead drops an omitted p* and falls back to OUTPUT.
    const bool boundarySwitches = (!left.contains(programKey) && right.contains(programKey))
        || (i + 1 == frames.size() - 1 && left.contains(programKey) && !right.contains(programKey));
    const QString comparator = boundarySwitches ? QStringLiteral("lt") : QStringLiteral("lte");
    expression = QStringLiteral("if(%1(t,%2),%3,%4)")
                     .arg(comparator, num(right.value(QStringLiteral("time")).toDouble()), interval, expression);
  }
  const QString before = first.contains(programKey) ? num(first.value(programKey).toDouble()) : outputExpr;
  return QStringLiteral("if(lt(t,%1),%2,%3)")
      .arg(num(first.value(QStringLiteral("time")).toDouble()), before, expression);
}

// Write a white circle mask PNG (size x size) for the "circulo" layout. Qt is our rasterizer.
static QString shapeMaskPng(const QString &dir, int w, int h, const QString &shape) {
  const QString f = dir + QStringLiteral("/mask-%1-%2x%3.png").arg(shape).arg(w).arg(h);
  if (QFileInfo::exists(f)) return f;
  QImage img(w, h, QImage::Format_ARGB32);
  img.fill(Qt::transparent);
  QPainter pt(&img);
  pt.setRenderHint(QPainter::Antialiasing);
  pt.setBrush(Qt::white);
  pt.setPen(Qt::NoPen);
  if (shape == QLatin1String("circle")) pt.drawEllipse(0, 0, w, h);
  else pt.drawRoundedRect(0, 0, w, h, w * 0.12, h * 0.12);   // rounded
  pt.end();
  img.save(f);
  return f;
}

static QString circleMaskPng(const QString &dir, int size) {
  return shapeMaskPng(dir, size, size, QStringLiteral("circle"));
}

// Per-block layout subgraph: [inLbl] -> [outLbl], both outW x outH.
// layout: "completa" | "apilar" | "pip" | "circulo"; regions in percent.
// sfx makes stream labels unique per block; maskLbl is the circle-mask input label (circulo only).
static QString layoutChain(const QString &inLbl, const QString &outLbl, const QString &layout,
                           const QVariantMap &regions, int srcW, int srcH,
                           const QString &sfx, const QString &maskLbl,
                           int outW, int outH) {
  if (layout == QLatin1String("apilar") && regions.contains(QStringLiteral("top"))) {
    const double split = qBound(0.15, regions.value(QStringLiteral("split"), 0.5).toDouble(), 0.85);
    const int topH = (int)(outH * split) / 2 * 2;
    const int botH = outH - topH;
    return QStringLiteral("[%1]split=2[t%5][b%5];[t%5]%2[zt%5];[b%5]%3[zb%5];[zt%5][zb%5]vstack=inputs=2[%4]")
        .arg(inLbl, cropChain(regions.value(QStringLiteral("top")).toMap(), srcW, srcH, outW, topH),
             cropChain(regions.value(QStringLiteral("bottom")).toMap(), srcW, srcH, outW, botH), outLbl, sfx);
  }
  if (layout == QLatin1String("pip") || layout == QLatin1String("circulo")) {
    const QVariantMap main = regions.value(QStringLiteral("main")).toMap();
    const QVariantMap fg = regions.value(QStringLiteral("fg")).toMap();
    const int side = qMin(outW, outH) / 2;
    const double fx = regions.value(QStringLiteral("fx"), 0.5).toDouble();
    const double fy = regions.value(QStringLiteral("fy"), 0.72).toDouble();
    const int ox = qBound(0, (int)(fx * outW - side / 2), outW - side);
    const int oy = qBound(0, (int)(fy * outH - side / 2), outH - side);
    const QString fgCrop = cropChain(fg.isEmpty() ? main : fg, srcW, srcH, side, side);
    QString fgOut = QStringLiteral("fgs%1").arg(sfx);
    QStringList parts;
    parts << QStringLiteral("[%1]split=2[%2][%3]").arg(inLbl, QStringLiteral("bg%1").arg(sfx), QStringLiteral("fg%1").arg(sfx));
    parts << QStringLiteral("[%1]%2[%3]").arg(QStringLiteral("bg%1").arg(sfx), cropChain(main, srcW, srcH, outW, outH), QStringLiteral("bgs%1").arg(sfx));
    if (layout == QLatin1String("circulo")) {
      parts << QStringLiteral("[%1]%2,format=rgba[fgr%3]").arg(QStringLiteral("fg%1").arg(sfx), fgCrop, sfx);
      parts << QStringLiteral("[fgr%1][%2]alphamerge[%3]").arg(sfx, maskLbl, fgOut);
    } else {
      parts << QStringLiteral("[%1]%2[%3]").arg(QStringLiteral("fg%1").arg(sfx), fgCrop, fgOut);
    }
    parts << QStringLiteral("[bgs%1][%2]overlay=%3:%4[%5]").arg(sfx, fgOut).arg(ox).arg(oy).arg(outLbl);
    return parts.join(QLatin1Char(';'));
  }
  // completa
  return QStringLiteral("[%1]%2[%3]").arg(inLbl, cropChain(regions.value(QStringLiteral("main")).toMap(), srcW, srcH, outW, outH), outLbl);
}

void EngineWorker::process() {
  forever {
    mutex.lock();
    while (queue.isEmpty() && !abort) cond.wait(&mutex);
    if (abort) { mutex.unlock(); return; }
    EngineTask task = queue.dequeue();
    mutex.unlock();

    if (task.kind == QLatin1String("thumb")) {
      const QString video = task.params.value(QStringLiteral("path")).toString();
      const QString thumbsDir = m_dataDir + QStringLiteral("/out/thumbs");
      QDir().mkpath(thumbsDir);
      const QString key = QString::fromLatin1(QCryptographicHash::hash(video.toUtf8(), QCryptographicHash::Md5).toHex());
      const QString dst = thumbsDir + QStringLiteral("/native_") + key + QStringLiteral(".jpg");
      if (!QFileInfo::exists(dst)) {
        double dur = probeDuration(video);
        double at = qMax(1.0, dur * 0.10);
        runProc(ffmpegBin(), {QStringLiteral("-v"),QStringLiteral("error"),QStringLiteral("-y"),
          QStringLiteral("-ss"),QString::number(at),QStringLiteral("-i"),video,
          QStringLiteral("-frames:v"),QStringLiteral("1"),QStringLiteral("-vf"),QStringLiteral("scale=320:-2"),
          QStringLiteral("-q:v"),QStringLiteral("4"),dst}, 60000);
      }
      if (QFileInfo::exists(dst))
        emit thumbReady(video, QUrl::fromLocalFile(dst).toString());
      continue;
    }

    if (task.kind == QLatin1String("strip")) {
      const QString video = task.params.value(QStringLiteral("path")).toString();
      const int frames = qMax(4, task.params.value(QStringLiteral("frames"), 16).toInt());
      const QString key = QString::fromLatin1(QCryptographicHash::hash(video.toUtf8(), QCryptographicHash::Md5).toHex());
      const QString dir = m_dataDir + QStringLiteral("/out/thumbs/strip_") + key;
      QDir().mkpath(dir);
      const QString dst = dir + QStringLiteral("/s_%02d.jpg");
      if (!QFileInfo::exists(dir + QStringLiteral("/s_00.jpg"))) {
        const double dur = probeDuration(video);
        if (dur > 0) {
          runProc(ffmpegBin(), {QStringLiteral("-v"),QStringLiteral("error"),QStringLiteral("-y"),
            QStringLiteral("-i"),video,
            QStringLiteral("-vf"),QStringLiteral("fps=%1/%2,scale=160:-2").arg(frames).arg(dur),
            QStringLiteral("-q:v"),QStringLiteral("5"),dst}, 120000);
        }
      }
      QStringList urls;
      const QStringList files = QDir(dir).entryList({QStringLiteral("s_*.jpg")}, QDir::Files, QDir::Name);
      for (const QString &f : files) urls << QUrl::fromLocalFile(dir + QLatin1Char('/') + f).toString();
      if (!urls.isEmpty()) emit stripReady(video, urls);
      continue;
    }

    if (task.kind == QLatin1String("cut")) {
      const QString src = task.params.value(QStringLiteral("path")).toString();
      const double start = task.params.value(QStringLiteral("start")).toDouble();
      const double end = task.params.value(QStringLiteral("end")).toDouble();
      const QString clipsDir = m_dataDir + QStringLiteral("/media/clips");
      QDir().mkpath(clipsDir);
      const QString clipId = QUuid::createUuid().toString(QUuid::WithoutBraces).left(32);
      const QString dst = clipsDir + QLatin1Char('/') + clipId + QStringLiteral(".mp4");
      QProcess p;
      p.start(ffmpegBin(), {QStringLiteral("-v"),QStringLiteral("error"),QStringLiteral("-y"),
        QStringLiteral("-nostdin"),
        QStringLiteral("-ss"),QString::number(start),QStringLiteral("-i"),src,
        QStringLiteral("-t"),QString::number(end - start),QStringLiteral("-c"),QStringLiteral("copy"),
        QStringLiteral("-movflags"),QStringLiteral("+faststart"),dst});
      m_procMutex.lock(); m_current = &p; m_procMutex.unlock();
      p.closeWriteChannel();
      p.waitForFinished(-1);
      m_procMutex.lock(); m_current = nullptr; m_procMutex.unlock();
      if (p.exitCode() == 0 && QFileInfo::exists(dst) && QFileInfo(dst).size() > 0)
        emit cutDone(clipId, dst, end - start);
      else {
        QFile::remove(dst);
        emit taskError(QStringLiteral("cut"), QStringLiteral("cut failed: ") + QString::fromLocal8Bit(p.readAllStandardError()).left(300));
      }
      continue;
    }

    if (task.kind == QLatin1String("transcribe")) {
      const QString python = qEnvironmentVariable("OMAREEL_ASR_PYTHON");
      const QString model = qEnvironmentVariable("OMAREEL_ASR_MODEL");
      QString script = qEnvironmentVariable("OMAREEL_ASR_SCRIPT");
      if (script.isEmpty()) {
        const QString bundled = QCoreApplication::applicationDirPath() + QStringLiteral("/scripts/transcribe_local.py");
        script = QFileInfo::exists(bundled) ? bundled : m_dataDir + QStringLiteral("/transcribe_local.py");
      }
      const QString clip = task.params.value(QStringLiteral("path")).toString();
      if (python.isEmpty() || model.isEmpty() || !QFileInfo::exists(script) || !QFileInfo::exists(model)) {
        emit taskError(QStringLiteral("subtitles"), QStringLiteral("Local ASR needs OMAREEL_ASR_PYTHON, OMAREEL_ASR_MODEL and transcribe_local.py."));
        continue;
      }
      const QString dir = m_dataDir + QStringLiteral("/out/subtitles"); QDir().mkpath(dir);
      const QString srt = dir + QLatin1Char('/') + QUuid::createUuid().toString(QUuid::WithoutBraces) + QStringLiteral(".srt");
      QProcess p;
      p.start(python, {script, model, clip, srt, task.params.value(QStringLiteral("language"), QStringLiteral("es")).toString()});
      m_procMutex.lock(); m_current = &p; m_procMutex.unlock();
      p.closeWriteChannel(); p.waitForFinished(-1);
      m_procMutex.lock(); m_current = nullptr; m_procMutex.unlock();
      if (p.exitCode() == 0 && QFileInfo::exists(srt)) emit subtitlesReady(srt);
      else emit taskError(QStringLiteral("subtitles"), QStringLiteral("Local ASR failed: ") + QString::fromLocal8Bit(p.readAllStandardError()).right(300));
      continue;
    }

    if (task.kind == QLatin1String("render")) {
      const QString jobId = task.params.value(QStringLiteral("jobId")).toString();
      const QString clip = task.params.value(QStringLiteral("clipPath")).toString();
      const QString tpl = task.params.value(QStringLiteral("template")).toString();
      const QVariantMap regions = task.params.value(QStringLiteral("regions")).toMap();
      const QVariantList layers = task.params.value(QStringLiteral("layers")).toList();
      const QString srt = task.params.value(QStringLiteral("srtPath")).toString();
      // output format: canvas size, layer coordinate space, codec/quality, filename suffix
      const int outW = qMax(2, task.params.value(QStringLiteral("width"), 1080).toInt());
      const int outH = qMax(2, task.params.value(QStringLiteral("height"), 1920).toInt());
      const bool progSpace = task.params.value(QStringLiteral("space")).toString() == QLatin1String("prog");
      const QString suffix = task.params.value(QStringLiteral("suffix")).toString();
      // layer coord in the active space: prog uses px/py (falls back to x/y), out uses x/y
      auto L = [progSpace](const QVariantMap &m, const QString &pk, const QString &ok, double def) {
        if (progSpace) return m.contains(pk) ? m.value(pk).toDouble() : m.value(ok, def).toDouble();
        return m.value(ok, def).toDouble();
      };

      // source dims + duration + fps
      QJsonObject st = probeJson(clip, QStringLiteral("stream=width,height:format=duration"));
      const QJsonObject vstream = st.value(QStringLiteral("streams")).toArray().first().toObject();
      const int srcW = vstream.value(QStringLiteral("width")).toInt();
      const int srcH = vstream.value(QStringLiteral("height")).toInt();
      const double dur = probeDuration(clip);
      const int fps = probeFps(clip);

      QStringList args;
      args << QStringLiteral("-y") << QStringLiteral("-nostdin") << QStringLiteral("-i") << clip;

      // rasterized text layer PNGs + gif/image inputs; track input index per layer
      QVariantList activeLayers;
      const QString tmpDir = m_dataDir + QStringLiteral("/media/clips/native-") + jobId;
      QDir().mkpath(tmpDir);
      int inIdx = 0;   // input 0 = clip; each layer input increments
      for (const QVariant &lv : layers) {
        QVariantMap layer = lv.toMap();
        const QString ltype = layer.value(QStringLiteral("type"), QStringLiteral("text")).toString();
        if (ltype == QLatin1String("text")) {
          if (layer.value(QStringLiteral("text")).toString().isEmpty()) continue;
          const QString png = tmpDir + QStringLiteral("/ov%1.png").arg(inIdx);
          {
            const QString fam = layer.value(QStringLiteral("font")).toString().isEmpty()
                ? QStringLiteral("DejaVu Sans") : layer.value(QStringLiteral("font")).toString();
            QFont font(fam);
            int rasterSize = layer.value(QStringLiteral("size")).toInt() > 0 ? layer.value(QStringLiteral("size")).toInt() : 90;
            for (const QVariant &frame : layer.value(QStringLiteral("keyframes")).toList())
              if (frame.toMap().contains(QStringLiteral("size")))
                rasterSize = qMax(rasterSize, qRound(frame.toMap().value(QStringLiteral("size")).toDouble()));
            font.setPixelSize(rasterSize);
            font.setBold(true);
            const QString text = layer.value(QStringLiteral("text")).toString();
            QFontMetrics fm(font);
            QRect tr = fm.boundingRect(QRect(0, 0, outW - 80, outH - 80), Qt::TextWordWrap, text);
            const int pad = qMax(10, rasterSize / 8);
            QImage img(qMax(2, tr.width() + pad * 2), qMax(2, tr.height() + pad * 2), QImage::Format_ARGB32);
            img.fill(Qt::transparent);
            QPainter tightPt(&img);
            tightPt.setRenderHint(QPainter::Antialiasing);
            tightPt.setFont(font);
            QRect box(pad, pad, tr.width(), tr.height());
            tightPt.setPen(QPen(Qt::black, qMax(3, font.pixelSize() / 14)));
            for (int dx = -2; dx <= 2; dx += 2)
              for (int dy = -2; dy <= 2; dy += 2)
                tightPt.drawText(box.translated(dx * 2, dy * 2), Qt::TextWordWrap | Qt::AlignHCenter, text);
            tightPt.setPen(QColor(layer.value(QStringLiteral("color"), QStringLiteral("#ffffff")).toString()));
            tightPt.drawText(box, Qt::TextWordWrap | Qt::AlignHCenter, text);
            tightPt.end();
            img.save(png);
            layer[QStringLiteral("_rasterSize")] = rasterSize;
            layer[QStringLiteral("_nativeW")] = img.width();
            layer[QStringLiteral("_nativeH")] = img.height();
          }
          inIdx++;
          args << QStringLiteral("-loop") << QStringLiteral("1") << QStringLiteral("-i") << png;
          layer[QStringLiteral("_inIdx")] = inIdx;
          activeLayers << layer;
        } else {
          // gif / image / video layer: input from file
          const QString file = layer.value(QStringLiteral("path")).toString();
          if (file.isEmpty() || !QFileInfo::exists(file)) continue;
          inIdx++;
          if (ltype == QLatin1String("gif"))
            args << QStringLiteral("-stream_loop") << QStringLiteral("-1") << QStringLiteral("-i") << file;
          else if (ltype == QLatin1String("video"))
            args << QStringLiteral("-i") << file;   // plays from its start while visible (enable=between)
          else
            args << QStringLiteral("-loop") << QStringLiteral("1") << QStringLiteral("-i") << file;
          layer[QStringLiteral("_inIdx")] = inIdx;
          // shape mask (rounded / circle) for gif / image / video layers
          const QString shape = layer.value(QStringLiteral("shape"), QStringLiteral("rect")).toString();
          if (shape != QLatin1String("rect")) {
            const int mw = qMax(2, (int)(L(layer, QStringLiteral("pw"), QStringLiteral("w"), 0.35) * outW));
            const int mh = qMax(2, (int)(L(layer, QStringLiteral("ph"), QStringLiteral("h"), 0.35) * outH));
            const QString maskFile = shapeMaskPng(tmpDir, mw, mh, shape);
            inIdx++;
            args << QStringLiteral("-loop") << QStringLiteral("1") << QStringLiteral("-i") << maskFile;
            layer[QStringLiteral("_maskIdx")] = inIdx;
          }
          activeLayers << layer;
        }
      }

      // filter graph
      QStringList fc;
      QString vPrev = QStringLiteral("0:v");

      // subtitles burn (before overlays)
      if (!srt.isEmpty()) {
        const QString tmpSrt = tmpDir + QStringLiteral("/subs.srt");
        QFile::remove(tmpSrt);
        QFile::copy(srt, tmpSrt);
        fc << QStringLiteral("[%1]subtitles='%2':force_style='FontSize=18,Outline=2'[vsrt]")
                  .arg(vPrev, tmpSrt);
        vPrev = QStringLiteral("vsrt");
      }

      // audio presence (segments need explicit concat windows)
      bool hasAudio = false;
      {
        const QJsonArray streams = probeJson(clip, QStringLiteral("stream=codec_type"))
            .value(QStringLiteral("streams")).toArray();
        for (const QJsonValue &sv : streams)
          if (sv.toObject().value(QStringLiteral("codec_type")).toString() == QLatin1String("audio")) hasAudio = true;
      }

      // template / blocks (segments with per-block layout)
      const QVariantList segs = task.params.value(QStringLiteral("segments")).toList();
      if (!segs.isEmpty()) {
        // circle mask input if any block uses "circulo"
        int nCirc = 0;
        for (const QVariant &sv : segs)
          if (sv.toMap().value(QStringLiteral("layout")).toString() == QLatin1String("circulo")) nCirc++;
        QString maskRaw;
        if (nCirc > 0) {
          const QString maskFile = circleMaskPng(tmpDir, qMin(outW, outH) / 2);
          inIdx++;
          args << QStringLiteral("-loop") << QStringLiteral("1") << QStringLiteral("-i") << maskFile;
          maskRaw = QStringLiteral("%1:v").arg(inIdx);
          // split once; each circulo block bounds its own copy (loop input is infinite)
          QStringList outs;
          for (int k = 0; k < nCirc; k++) outs << QStringLiteral("[mraw%1]").arg(k);
          fc << QStringLiteral("[%1]split=%2%3").arg(maskRaw).arg(nCirc).arg(outs.join(QString()));
        }
        QStringList vIns, aIns;
        int si = 0, ci = 0;
        for (const QVariant &sv : segs) {
          const QVariantMap seg = sv.toMap();
          const double ss = seg.value(QStringLiteral("start")).toDouble();
          const double ee = seg.value(QStringLiteral("end")).toDouble();
          const QString sfx = QStringLiteral("s%1").arg(si);
          fc << QStringLiteral("[%1]trim=start=%2:end=%3,setpts=PTS-STARTPTS[%4]")
                    .arg(vPrev).arg(ss).arg(ee).arg(QStringLiteral("vs%1").arg(sfx));
          QString maskLbl;
          if (seg.value(QStringLiteral("layout")).toString() == QLatin1String("circulo")) {
            maskLbl = QStringLiteral("mask_%1").arg(sfx);
            fc << QStringLiteral("[mraw%1]trim=duration=%2,setpts=PTS-STARTPTS[%3]").arg(ci).arg(ee - ss).arg(maskLbl);
            ci++;
          }
          fc << layoutChain(QStringLiteral("vs%1").arg(sfx), QStringLiteral("bn%1").arg(sfx),
                            seg.value(QStringLiteral("layout"), QStringLiteral("completa")).toString(),
                            seg.value(QStringLiteral("regions")).toMap(), srcW, srcH, sfx, maskLbl,
                            outW, outH);
          // normalize SAR: per-layout scale/crop paths can disagree by 1px rounding
          fc << QStringLiteral("[bn%1]setsar=1[b%1]").arg(sfx);
          vIns << QStringLiteral("[b%1]").arg(sfx);
          if (hasAudio) {
            fc << QStringLiteral("[0:a]atrim=start=%1:end=%2,asetpts=PTS-STARTPTS[%3]")
                      .arg(ss).arg(ee).arg(QStringLiteral("as%1").arg(sfx));
            aIns << QStringLiteral("[as%1]").arg(sfx);
          }
          si++;
        }
        fc << vIns.join(QString()) + QStringLiteral("concat=n=%1:v=1:a=0[vbase]").arg(si);
        if (hasAudio)
          fc << aIns.join(QString()) + QStringLiteral("concat=n=%1:v=0:a=1[a_base]").arg(si);
        vPrev = QStringLiteral("vbase");
      } else if (tpl == QLatin1String("apilar") && regions.contains(QStringLiteral("top"))) {
        const double split = qBound(0.15, regions.value(QStringLiteral("split"), 0.5).toDouble(), 0.85);
        const int topH = (int)(outH * split) / 2 * 2;
        const int botH = outH - topH;
        fc << QStringLiteral("[%1]split=2[vt][vb]").arg(vPrev);
        fc << QStringLiteral("[vt]%1[zt]").arg(cropChain(regions.value(QStringLiteral("top")).toMap(), srcW, srcH, outW, topH));
        fc << QStringLiteral("[vb]%1[zb]").arg(cropChain(regions.value(QStringLiteral("bottom")).toMap(), srcW, srcH, outW, botH));
        fc << QStringLiteral("[zt][zb]vstack=inputs=2[vbase]");
        vPrev = QStringLiteral("vbase");
      } else {
        fc << QStringLiteral("[%1]%2[vbase]").arg(vPrev, cropChain(regions.value(QStringLiteral("main")).toMap(), srcW, srcH, outW, outH));
        vPrev = QStringLiteral("vbase");
      }

      // overlays (bound each infinite input to the BASE TIMELINE: with blocks,
      // the concat output is shorter than the clip; an overlay trimmed to the
      // full clip would stretch the output past the audio)
      double baseDur = dur;
      if (!segs.isEmpty()) {
        baseDur = 0;
        for (const QVariant &sv : segs)
          baseDur += sv.toMap().value(QStringLiteral("end")).toDouble()
                   - sv.toMap().value(QStringLiteral("start")).toDouble();
      }
      int oi = 0;
      for (const QVariant &lv : activeLayers) {
        const QVariantMap layer = lv.toMap();
        const QString ltype = layer.value(QStringLiteral("type"), QStringLiteral("text")).toString();
        const int n = layer.value(QStringLiteral("_inIdx")).toInt();
        // layer timing: QML/UI uses inS/outS (seconds on the output timeline)
        const double in = layer.value(QStringLiteral("inS"), layer.value(QStringLiteral("in"), 0.0)).toDouble();
        double out = layer.value(QStringLiteral("outS"), layer.value(QStringLiteral("out"), baseDur)).toDouble();
        out = qBound(in + 0.1, out, baseDur);
        const double tdur = out - in;
        const QString gx = animatedLayerValue(layer, progSpace, QStringLiteral("px"), QStringLiteral("x"), 0.5);
        const QString gy = animatedLayerValue(layer, progSpace, QStringLiteral("py"), QStringLiteral("y"), 0.5);
        QString wExpr, hExpr;
        if (ltype == QLatin1String("text")) {
          const QString size = animatedValue(layer, QStringLiteral("size"), 90.0);
          const int rasterSize = qMax(1, layer.value(QStringLiteral("_rasterSize"), 90).toInt());
          wExpr = QStringLiteral("max(2,%1*(%2)/%3)").arg(layer.value(QStringLiteral("_nativeW")).toInt()).arg(size).arg(rasterSize);
          hExpr = QStringLiteral("max(2,%1*(%2)/%3)").arg(layer.value(QStringLiteral("_nativeH")).toInt()).arg(size).arg(rasterSize);
        } else {
          const QString gw = animatedLayerValue(layer, progSpace, QStringLiteral("pw"), QStringLiteral("w"), 0.35);
          const QString gh = animatedLayerValue(layer, progSpace, QStringLiteral("ph"), QStringLiteral("h"), 0.35);
          wExpr = QStringLiteral("max(2,%1*(%2))").arg(outW).arg(gw);
          hExpr = QStringLiteral("max(2,%1*(%2))").arg(outH).arg(gh);
        }
        const QString chain = QStringLiteral("trim=duration=%1,setpts=PTS-STARTPTS+%2/TB,format=yuva420p,scale=w='%3':h='%4':eval=frame")
                                  .arg(num(tdur), num(in), wExpr, hExpr);
        const int maskIdx = layer.value(QStringLiteral("_maskIdx"), -1).toInt();
        if (maskIdx > 0) {
          fc << QStringLiteral("[%1:v]%2,format=rgba[ovg%3]").arg(n).arg(chain).arg(oi);
          fc << QStringLiteral("[%1:v]trim=duration=%2,setpts=PTS-STARTPTS+%3/TB,scale=w='%4':h='%5':eval=frame[ovm%6]")
                    .arg(maskIdx).arg(num(tdur), num(in), wExpr, hExpr).arg(oi);
          fc << QStringLiteral("[ovg%1][ovm%1]alphamerge[ovraw%1]").arg(oi);
        } else {
          fc << QStringLiteral("[%1:v]%2[ovraw%3]").arg(n).arg(chain).arg(oi);
        }
        QString alphaChain;
        const double fadeIn = qBound(0.0, layer.value(QStringLiteral("fadeIn"), 0.0).toDouble(), tdur);
        const double fadeOut = qBound(0.0, layer.value(QStringLiteral("fadeOut"), 0.0).toDouble(), tdur);
        if (fadeIn > 0.0001) alphaChain += QStringLiteral(",fade=t=in:st=%1:d=%2:alpha=1").arg(num(in), num(fadeIn));
        if (fadeOut > 0.0001) alphaChain += QStringLiteral(",fade=t=out:st=%1:d=%2:alpha=1").arg(num(out - fadeOut), num(fadeOut));
        bool hasAnimatedOpacity = false;
        for (const QVariant &frame : layer.value(QStringLiteral("keyframes")).toList())
          hasAnimatedOpacity = hasAnimatedOpacity || frame.toMap().contains(QStringLiteral("opacity"));
        const double opacity = qBound(0.0, layer.value(QStringLiteral("opacity"), 1.0).toDouble(), 1.0);
        if (hasAnimatedOpacity || opacity < 0.9999) {
          QString opacityExpr = animatedValue(layer, QStringLiteral("opacity"), 1.0);
          opacityExpr.replace(QRegularExpression(QStringLiteral("\\bt\\b")), QStringLiteral("T"));
          alphaChain += QStringLiteral(",format=rgba,geq=r='r(X,Y)':g='g(X,Y)':b='b(X,Y)':a='alpha(X,Y)*clip(%1,0,1)'")
                            .arg(opacityExpr);
        }
        fc << QStringLiteral("[ovraw%1]%2[ovb%1]").arg(oi).arg(alphaChain.isEmpty() ? QStringLiteral("null") : alphaChain.mid(1));
        const QString ox = QStringLiteral("main_w*(%1)-overlay_w/2").arg(gx);
        const QString oy = QStringLiteral("main_h*(%1)-overlay_h/2").arg(gy);
        fc << QStringLiteral("[%1][ovb%2]overlay=x='%3':y='%4':eval=frame:enable='between(t,%5,%6)'[vo%7]")
                  .arg(vPrev).arg(oi).arg(ox, oy, num(in), num(out)).arg(oi);
        vPrev = QStringLiteral("vo%1").arg(oi);
        oi++;
      }

      args << QStringLiteral("-filter_complex") << fc.join(QLatin1Char(';'));
      args << QStringLiteral("-map") << QStringLiteral("[%1]").arg(vPrev);
      if (!segs.isEmpty()) { if (hasAudio) args << QStringLiteral("-map") << QStringLiteral("[a_base]"); }
      else args << QStringLiteral("-map") << QStringLiteral("0:a?");

      const QString outPath = m_dataDir + QStringLiteral("/out/") + jobId + suffix + QStringLiteral(".mp4");
      args << QStringLiteral("-progress") << QStringLiteral("pipe:1");
      // codec/quality: h264 (default) | h265 | vp9, crf + preset from the render panel
      const QString codec = task.params.value(QStringLiteral("codec"), QStringLiteral("h264")).toString();
      const int crf = task.params.value(QStringLiteral("crf"), 18).toInt();
      const QString preset = task.params.value(QStringLiteral("preset"), QStringLiteral("veryfast")).toString();
      if (codec == QLatin1String("h265")) {
        args << QStringLiteral("-c:v") << QStringLiteral("libx265") << QStringLiteral("-preset") << preset
             << QStringLiteral("-crf") << QString::number(crf) << QStringLiteral("-tag:v") << QStringLiteral("hvc1");
      } else if (codec == QLatin1String("vp9")) {
        args << QStringLiteral("-c:v") << QStringLiteral("libvpx-vp9") << QStringLiteral("-crf") << QString::number(crf)
             << QStringLiteral("-b:v") << QStringLiteral("0") << QStringLiteral("-row-mt") << QStringLiteral("1")
             << QStringLiteral("-cpu-used") << (preset == QLatin1String("slow") ? QStringLiteral("1") : QStringLiteral("2"));
      } else {
        args << QStringLiteral("-c:v") << QStringLiteral("libx264") << QStringLiteral("-preset") << preset
             << QStringLiteral("-crf") << QString::number(crf);
      }
      args << QStringLiteral("-threads") << QStringLiteral("2") << QStringLiteral("-pix_fmt") << QStringLiteral("yuv420p")
           << QStringLiteral("-c:a") << QStringLiteral("aac") << QStringLiteral("-b:a") << QStringLiteral("128k")
           << QStringLiteral("-movflags") << QStringLiteral("+faststart");
      args << QStringLiteral("-r") << QString::number(fps) << outPath;

      QProcess p;
      p.start(ffmpegBin(), args);
      m_procMutex.lock(); m_current = &p; m_procMutex.unlock();
      p.closeWriteChannel();
      // progress from stdout (-progress pipe:1); drain stderr too so ffmpeg never blocks
      while (p.state() == QProcess::Running) {
        p.waitForReadyRead(500);
        p.readAllStandardError();
        const QByteArray out = p.readAllStandardOutput();
        for (const QByteArray &line : out.split('\n')) {
          if (line.startsWith("out_time_us=")) {
            const double t = line.mid(12).toDouble() / 1e6;
            if (dur > 0) emit renderProgress(jobId, qMin(0.99, t / dur));
          }
        }
      }
      p.waitForFinished(-1);
      m_procMutex.lock(); m_current = nullptr; m_procMutex.unlock();
      QDir(tmpDir).removeRecursively();
      if (p.exitCode() == 0 && QFileInfo::exists(outPath)) {
        emit renderProgress(jobId, 1.0);
        emit renderDone(jobId, outPath);
      } else {
        QFile::remove(outPath);
        emit taskError(jobId, QStringLiteral("render failed: ") + QString::fromLocal8Bit(p.readAllStandardError()).right(400));
      }
      continue;
    }
  }
}

/* ----------------------------- engine ----------------------------- */

OmareelEngine::OmareelEngine(QObject *parent) : QObject(parent) {
  m_dataDir = qEnvironmentVariableIsSet("OMAREEL_DATA")
      ? QString::fromLocal8Bit(qgetenv("OMAREEL_DATA"))
      : QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
  for (const QString &sub : {QStringLiteral("media"), QStringLiteral("media/clips"), QStringLiteral("out"), QStringLiteral("out/thumbs")})
    QDir().mkpath(m_dataDir + QLatin1Char('/') + sub);
  m_projectFile = m_dataDir + QStringLiteral("/project.json");
  const QString themeOverride = qEnvironmentVariable("OMAREEL_THEME_FILE");
  m_themePaths = themeOverride.isEmpty()
      ? QStringList{QDir::homePath() + QStringLiteral("/.local/state/omarchy/current/theme/colors.toml"),
                    QDir::homePath() + QStringLiteral("/.config/omarchy/current/theme/colors.toml")}
      : QStringList{themeOverride};
  m_themeDebounce.setSingleShot(true); m_themeDebounce.setInterval(90);
  connect(&m_themeDebounce, &QTimer::timeout, this, [this] { watchTheme(); loadTheme(); });
  connect(&m_themeWatcher, &QFileSystemWatcher::fileChanged, this, [this](const QString &) { m_themeDebounce.start(); });
  connect(&m_themeWatcher, &QFileSystemWatcher::directoryChanged, this, [this](const QString &) { m_themeDebounce.start(); });
  m_themeRecovery.setInterval(2000);
  connect(&m_themeRecovery, &QTimer::timeout, this, [this] { watchTheme(); loadTheme(); });
  m_themeRecovery.start();
  loadTheme();
  watchTheme();

  m_worker = new EngineWorker(m_dataDir);
  m_worker->moveToThread(&m_thread);
  connect(&m_thread, &QThread::started, m_worker, &EngineWorker::process);
  connect(m_worker, &EngineWorker::thumbReady, this, &OmareelEngine::thumbReady, Qt::QueuedConnection);
  connect(m_worker, &EngineWorker::stripReady, this, &OmareelEngine::stripReady, Qt::QueuedConnection);
  connect(m_worker, &EngineWorker::cutDone, this, &OmareelEngine::cutDone, Qt::QueuedConnection);
  connect(m_worker, &EngineWorker::renderProgress, this, &OmareelEngine::renderProgress, Qt::QueuedConnection);
  connect(m_worker, &EngineWorker::renderDone, this, &OmareelEngine::renderDone, Qt::QueuedConnection);
  connect(m_worker, &EngineWorker::taskError, this, &OmareelEngine::taskError, Qt::QueuedConnection);
  connect(m_worker, &EngineWorker::subtitlesReady, this, &OmareelEngine::subtitlesReady, Qt::QueuedConnection);
  m_thread.start();
  // live-reload project.json on EXTERNAL edits (AI-editable project file)
  watchProjectFile();
  connect(&m_projWatcher, &QFileSystemWatcher::fileChanged, this, [this](const QString &path) {
    if (QFileInfo::exists(path) && !m_projWatcher.files().contains(path))
      m_projWatcher.addPath(path);   // re-arm after atomic replace
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly)) return;
    const QByteArray bytes = f.readAll();
    if (QCryptographicHash::hash(bytes, QCryptographicHash::Sha1) == m_lastProjHash) return;  // self-write
    const QJsonDocument d = QJsonDocument::fromJson(bytes);
    if (d.isObject()) emit projectChangedExternally(resolveProjectPaths(d.object().toVariantMap(), path));
  });
}

void OmareelEngine::watchTheme() {
  QStringList observed;
  for (const QString &path : m_themePaths) {
    for (QString p = path; p != QDir::rootPath(); p = QFileInfo(p).absolutePath())
      if (QFileInfo::exists(p)) observed << p;
    const QString resolved = QFileInfo(path).canonicalFilePath();
    if (!resolved.isEmpty()) observed << resolved << QFileInfo(resolved).absolutePath();
  }
  observed.removeDuplicates();
  const QStringList old = m_themeWatcher.files() + m_themeWatcher.directories();
  if (!old.isEmpty()) m_themeWatcher.removePaths(old);
  if (!observed.isEmpty()) m_themeWatcher.addPaths(observed);
}

void OmareelEngine::loadTheme() {
  QVariantMap next{{"app", "#1a1b26"}, {"panel", "#1f2335"}, {"panelAlt", "#24283b"},
                   {"panelDeep", "#16161e"}, {"border", "#292e42"}, {"borderSoft", "#232638"},
                   {"text", "#c0caf5"}, {"textMuted", "#7982a9"}, {"textDim", "#565f89"},
                   {"accent", "#7aa2f7"}, {"accentSoft", "#2f3d5e"}, {"play", "#9ece6a"},
                   {"record", "#f7768e"}, {"playhead", "#f7768e"}, {"warn", "#e0af68"},
                   {"good", "#9ece6a"}, {"bad", "#f7768e"}, {"orange", "#ff9e64"},
                   {"magenta", "#bb9af7"}, {"cyan", "#7dcfff"}, {"radius", 6},
                   {"fontUi", "Noto Sans"}, {"fontMono", "Noto Sans Mono"}};
  QVariantMap raw;
  const QRegularExpression re(QStringLiteral(R"(^\s*([a-z_]+)\s*=\s*[\"'](#[0-9A-Fa-f]{6,8})[\"']\s*(?:#.*)?$)"));
  for (const QString &path : m_themePaths) {
    QFile f(path); if (!f.open(QIODevice::ReadOnly)) continue;
    const QByteArray bytes = f.read(65537); if (bytes.size() > 65536) continue;
    QVariantMap parsed;
    for (const QString &line : QString::fromUtf8(bytes).split(QLatin1Char('\n'))) {
      const QRegularExpressionMatch m = re.match(line);
      if (m.hasMatch()) parsed[m.captured(1)] = m.captured(2).toLower();
    }
    if (parsed.contains(QStringLiteral("background")) && parsed.contains(QStringLiteral("foreground")) && parsed.contains(QStringLiteral("accent"))) { raw = parsed; break; }
  }
  if (raw.isEmpty() && !m_theme.isEmpty()) return; // retain the last valid palette through partial writes
  auto color = [&raw](const char *name, const QVariant &fallback) { return raw.value(QString::fromLatin1(name), fallback); };
  next["app"] = color("background", next["app"]);
  next["panel"] = color("lighter_background", next["panel"]);
  next["panelAlt"] = color("selection", next["panelAlt"]);
  next["panelDeep"] = color("darker_background", next["panelDeep"]);
  next["border"] = color("muted", next["border"]);
  next["borderSoft"] = color("dark_background", next["borderSoft"]);
  next["text"] = color("foreground", next["text"]);
  next["textMuted"] = color("light_foreground", color("dark_foreground", next["textMuted"]));
  next["textDim"] = color("muted", next["textDim"]);
  next["accent"] = color("accent", next["accent"]);
  next["accentSoft"] = color("selection", next["accentSoft"]);
  next["play"] = color("bright_green", color("green", next["play"]));
  next["good"] = next["play"];
  next["record"] = color("bright_red", color("red", next["record"]));
  next["bad"] = next["record"];
  next["playhead"] = next["record"];
  next["warn"] = color("yellow", next["warn"]);
  next["orange"] = color("orange", next["orange"]);
  next["magenta"] = color("magenta", next["magenta"]);
  next["cyan"] = color("cyan", next["cyan"]);
  if (next != m_theme) { m_theme = next; emit themeChanged(); }
}

void OmareelEngine::watchProjectFile() {
  if (QFileInfo::exists(m_projectFile) && !m_projWatcher.files().contains(m_projectFile))
    m_projWatcher.addPath(m_projectFile);
}

bool OmareelEngine::setProjectFile(const QString &fileUrl) {
  const QUrl url(fileUrl);
  const QString file = url.isLocalFile() ? url.toLocalFile() : fileUrl;
  if (file.isEmpty()) return false;
  const QString resolved = QFileInfo(file).absoluteFilePath();
  if (resolved == m_projectFile) return true;
  m_projWatcher.removePaths(m_projWatcher.files());
  m_projectFile = resolved;
  watchProjectFile();
  emit projectFileChanged();
  return true;
}

OmareelEngine::~OmareelEngine() {
  m_worker->mutex.lock();
  m_worker->abort = true;
  m_worker->cond.wakeAll();
  m_worker->mutex.unlock();
  m_worker->killCurrent();          // unblock a running ffmpeg
  m_thread.quit();
  if (!m_thread.wait(15000)) {
    m_thread.terminate();           // last resort: never abort on exit
    m_thread.wait(2000);
  }
}

void OmareelEngine::setLanguage(const QString &l) {
  if (m_lang == l) return;
  m_lang = l;
  emit languageChanged();
}

void OmareelEngine::enqueue(const EngineTask &t) {
  m_worker->mutex.lock();
  m_worker->queue.enqueue(t);
  m_worker->cond.wakeOne();
  m_worker->mutex.unlock();
}

QVariantList OmareelEngine::scanMedia() {
  QVariantList out;
  const QDir dir(m_dataDir + QStringLiteral("/media"));
  const QStringList exts = {QStringLiteral("*.mp4"), QStringLiteral("*.mkv"), QStringLiteral("*.mov"), QStringLiteral("*.webm")};
  const QFileInfoList files = dir.entryInfoList(exts, QDir::Files, QDir::Time);
  for (const QFileInfo &fi : files) {
    if (fi.fileName().startsWith(QLatin1String("upload-"))) continue;
    QVariantMap m;
    m[QStringLiteral("id")] = fi.completeBaseName();
    m[QStringLiteral("path")] = fi.absoluteFilePath();
    m[QStringLiteral("title")] = fi.completeBaseName();
    m[QStringLiteral("size")] = fi.size();
    m[QStringLiteral("mtime")] = fi.lastModified().toString(Qt::ISODate);
    m[QStringLiteral("duration")] = probeDuration(fi.absoluteFilePath());
    out << m;
  }
  return out;
}

QVariantMap OmareelEngine::probeVideo(const QString &path) {
  const auto it = m_probeCache.constFind(path);
  if (it != m_probeCache.constEnd()) return it.value();
  QVariantMap m;
  const QJsonObject st = probeJson(path, QStringLiteral("stream=width,height:format=duration"));
  const QJsonObject vs = st.value(QStringLiteral("streams")).toArray().first().toObject();
  m[QStringLiteral("width")] = vs.value(QStringLiteral("width")).toInt();
  m[QStringLiteral("height")] = vs.value(QStringLiteral("height")).toInt();
  m[QStringLiteral("duration")] = probeDuration(path);
  m_probeCache.insert(path, m);
  return m;
}

QString OmareelEngine::cachedThumb(const QString &videoPath) {
  const QString key = QString::fromLatin1(QCryptographicHash::hash(videoPath.toUtf8(), QCryptographicHash::Md5).toHex());
  const QString f = m_dataDir + QStringLiteral("/out/thumbs/native_") + key + QStringLiteral(".jpg");
  return QFileInfo::exists(f) ? QUrl::fromLocalFile(f).toString() : QString();
}

void OmareelEngine::requestThumb(const QString &videoPath) {
  if (!cachedThumb(videoPath).isEmpty()) { emit thumbReady(videoPath, cachedThumb(videoPath)); return; }
  EngineTask t; t.kind = QStringLiteral("thumb"); t.params[QStringLiteral("path")] = videoPath;
  enqueue(t);
}

QStringList OmareelEngine::cachedStrip(const QString &videoPath) {
  const QString key = QString::fromLatin1(QCryptographicHash::hash(videoPath.toUtf8(), QCryptographicHash::Md5).toHex());
  const QString dir = m_dataDir + QStringLiteral("/out/thumbs/strip_") + key;
  QStringList urls;
  const QStringList files = QDir(dir).entryList({QStringLiteral("s_*.jpg")}, QDir::Files, QDir::Name);
  for (const QString &f : files) urls << QUrl::fromLocalFile(dir + QLatin1Char('/') + f).toString();
  return urls;
}

void OmareelEngine::requestStrip(const QString &videoPath, int frames) {
  const QStringList c = cachedStrip(videoPath);
  if (!c.isEmpty()) { emit stripReady(videoPath, c); return; }
  EngineTask t; t.kind = QStringLiteral("strip");
  t.params[QStringLiteral("path")] = videoPath;
  t.params[QStringLiteral("frames")] = frames;
  enqueue(t);
}

QString OmareelEngine::importVideo(const QString &fileUrl) {
  const QUrl sourceUrl(fileUrl);
#ifdef Q_OS_ANDROID
  if (sourceUrl.scheme() == QLatin1String("content")) {
    const QJniObject context = QNativeInterface::QAndroidApplication::context();
    const QJniObject resolver = context.callObjectMethod(
        "getContentResolver", "()Landroid/content/ContentResolver;");
    const QJniObject uri = QJniObject::callStaticObjectMethod(
        "android/net/Uri", "parse", "(Ljava/lang/String;)Landroid/net/Uri;",
        QJniObject::fromString(fileUrl).object<jstring>());
    if (!resolver.isValid() || !uri.isValid()) return {};

    QString displayName;
    QJniObject cursor = resolver.callObjectMethod(
        "query", "(Landroid/net/Uri;[Ljava/lang/String;Ljava/lang/String;[Ljava/lang/String;Ljava/lang/String;)Landroid/database/Cursor;",
        uri.object<jobject>(), static_cast<jobjectArray>(nullptr), static_cast<jstring>(nullptr),
        static_cast<jobjectArray>(nullptr), static_cast<jstring>(nullptr));
    if (cursor.isValid() && cursor.callMethod<jboolean>("moveToFirst", "()Z")) {
      const int column = cursor.callMethod<jint>(
          "getColumnIndex", "(Ljava/lang/String;)I",
          QJniObject::fromString(QStringLiteral("_display_name")).object<jstring>());
      if (column >= 0)
        displayName = cursor.callObjectMethod("getString", "(I)Ljava/lang/String;", column).toString();
    }
    if (cursor.isValid()) cursor.callMethod<void>("close", "()V");
    displayName = QFileInfo(displayName).fileName();
    displayName.replace(QRegularExpression(QStringLiteral("[^A-Za-z0-9._ -]")), QStringLiteral("_"));
    if (displayName.isEmpty()) displayName = QUuid::createUuid().toString(QUuid::WithoutBraces) + QStringLiteral(".mp4");
    if (QFileInfo(displayName).suffix().isEmpty()) displayName += QStringLiteral(".mp4");
    const QString dst = m_dataDir + QStringLiteral("/media/") + displayName;
    if (QFileInfo::exists(dst)) return dst;

    const QJniObject mode = QJniObject::fromString(QStringLiteral("r"));
    QJniObject parcel = resolver.callObjectMethod(
        "openFileDescriptor", "(Landroid/net/Uri;Ljava/lang/String;)Landroid/os/ParcelFileDescriptor;",
        uri.object<jobject>(), mode.object<jstring>());
    if (!parcel.isValid()) return {};
    const int fd = parcel.callMethod<jint>("detachFd", "()I");
    QFile input;
    QSaveFile output(dst);
    if (fd < 0 || !input.open(fd, QIODevice::ReadOnly, QFileDevice::AutoCloseHandle)
        || !output.open(QIODevice::WriteOnly)) return {};
    QByteArray chunk(1024 * 1024, Qt::Uninitialized);
    for (;;) {
      const qint64 count = input.read(chunk.data(), chunk.size());
      if (count < 0) return {};
      if (count == 0) break;
      if (output.write(chunk.constData(), count) != count) return {};
    }
    return output.commit() ? dst : QString();
  }
#endif
  const QString src = sourceUrl.toLocalFile();
  if (src.isEmpty()) return {};
  const QString dst = m_dataDir + QStringLiteral("/media/") + QFileInfo(src).fileName();
  if (QFileInfo::exists(dst)) return dst;
  if (QFile::link(src, dst)) return dst;      // hardlink: instant, same filesystem
  if (QFile::copy(src, dst)) return dst;      // fallback
  return {};
}

void OmareelEngine::deleteMedia(const QString &path) {
  QFile::remove(path);
}

QVariantList OmareelEngine::listOutputs() {
  QVariantList out;
  const QDir dir(m_dataDir + QStringLiteral("/out"));
  const QFileInfoList files = dir.entryInfoList({QStringLiteral("*.mp4")}, QDir::Files, QDir::Time);
  for (const QFileInfo &fi : files) {
    QVariantMap m;
    m[QStringLiteral("path")] = fi.absoluteFilePath();
    m[QStringLiteral("name")] = fi.fileName();
    m[QStringLiteral("size")] = fi.size();
    m[QStringLiteral("mtime")] = fi.lastModified().toString(Qt::ISODate);
    m[QStringLiteral("thumb")] = cachedThumb(fi.absoluteFilePath());
    out << m;
  }
  return out;
}

void OmareelEngine::openFolder(const QString &path) {
  QDesktopServices::openUrl(QUrl::fromLocalFile(QFileInfo(path).absolutePath()));
}

void OmareelEngine::cut(const QString &sessionPath, double start, double end) {
  EngineTask t; t.kind = QStringLiteral("cut");
  t.params[QStringLiteral("path")] = sessionPath;
  t.params[QStringLiteral("start")] = start;
  t.params[QStringLiteral("end")] = end;
  enqueue(t);
}

void OmareelEngine::renderVertical(const QVariantMap &params) {
  EngineTask t; t.kind = QStringLiteral("render");
  t.params = params;
  t.params[QStringLiteral("jobId")] = QUuid::createUuid().toString(QUuid::WithoutBraces).left(32);
  // hand the generated id back via progress 0 signal so QML can track it
  enqueue(t);
  emit renderProgress(t.params[QStringLiteral("jobId")].toString(), 0.0);
}

void OmareelEngine::transcribeAudio(const QString &clipPath, const QString &language) {
  if (clipPath.isEmpty() || !QFileInfo::exists(clipPath)) {
    emit taskError(QStringLiteral("subtitles"), QStringLiteral("No clip selected for transcription."));
    return;
  }
  EngineTask t; t.kind = QStringLiteral("transcribe");
  t.params = {{QStringLiteral("path"), clipPath}, {QStringLiteral("language"), language}};
  enqueue(t);
}

QVariantList OmareelEngine::subtitleLayers(const QString &srtPath, bool reelStyle) const {
  QFile f(srtPath); if (!f.open(QIODevice::ReadOnly | QIODevice::Text)) return {};
  const QRegularExpression cue(QStringLiteral(R"(\d+\s*\n(\d\d):(\d\d):(\d\d),(\d\d\d)\s*-->\s*(\d\d):(\d\d):(\d\d),(\d\d\d)\s*\n(.*?)(?:\n\s*\n|$))"), QRegularExpression::DotMatchesEverythingOption);
  const QString doc = QString::fromUtf8(f.readAll());
  QVariantList layers;
  auto matches = cue.globalMatch(doc);
  while (matches.hasNext()) {
    const auto m = matches.next();
    const QString text = m.captured(9).trimmed().replace(QLatin1Char('\n'), QLatin1Char(' '));
    if (text.isEmpty()) continue;
    const double in = m.captured(1).toDouble() * 3600 + m.captured(2).toDouble() * 60 + m.captured(3).toDouble() + m.captured(4).toDouble() / 1000;
    const double out = m.captured(5).toDouble() * 3600 + m.captured(6).toDouble() * 60 + m.captured(7).toDouble() + m.captured(8).toDouble() / 1000;
    layers << QVariantMap{{"type", "text"}, {"text", text}, {"x", 0.5}, {"y", reelStyle ? 0.72 : 0.88},
      {"size", reelStyle ? 72 : 54}, {"color", "#ffffff"}, {"font", ""}, {"inS", in}, {"outS", out},
      {"subtitle", true}, {"subtitleStyle", reelStyle ? "reel" : "normal"}};
  }
  return layers;
}

QString OmareelEngine::rasterizeText(const QVariantMap &layer) {
  const QString tmp = QDir::temp().absoluteFilePath(
      QStringLiteral("omareel-prev-%1.png").arg(QUuid::createUuid().toString(QUuid::WithoutBraces).left(8)));
  QImage img(270, 480, QImage::Format_ARGB32);   // small preview
  img.fill(Qt::transparent);
  QPainter pt(&img);
  pt.setRenderHint(QPainter::Antialiasing);
  const QString fam = layer.value(QStringLiteral("font")).toString().isEmpty()
      ? QStringLiteral("DejaVu Sans") : layer.value(QStringLiteral("font")).toString();
  QFont font(fam);
  font.setPixelSize(qMax(8, layer.value(QStringLiteral("size")).toInt() / 4));
  font.setBold(true);
  pt.setFont(font);
  pt.setPen(QColor(layer.value(QStringLiteral("color"), QStringLiteral("#ffffff")).toString()));
  pt.drawText(img.rect(), Qt::TextWordWrap | Qt::AlignHCenter | Qt::AlignVCenter, layer.value(QStringLiteral("text")).toString());
  pt.end();
  img.save(tmp);
  return QUrl::fromLocalFile(tmp).toString();
}

static QString resolveProjectPath(const QString &value, const QString &projectFile) {
  if (value.isEmpty() || QFileInfo(value).isAbsolute() || !QUrl(value).scheme().isEmpty()) return value;
  return QDir(QFileInfo(projectFile).absolutePath()).absoluteFilePath(value);
}

static QVariantMap resolveProjectPaths(QVariantMap doc, const QString &projectFile) {
  QVariantMap hints;
  auto resolve = [&](const QString &value) {
    const QString resolved = resolveProjectPath(value, projectFile);
    if (!value.isEmpty() && value != resolved) hints[resolved] = value;
    return resolved;
  };
  doc[QStringLiteral("video")] = resolve(doc.value(QStringLiteral("video")).toString());
  doc[QStringLiteral("srt")] = resolve(doc.value(QStringLiteral("srt")).toString());
  QVariantList layers = doc.value(QStringLiteral("layers")).toList();
  for (QVariant &value : layers) {
    QVariantMap layer = value.toMap();
    layer[QStringLiteral("path")] = resolve(layer.value(QStringLiteral("path")).toString());
    value = layer;
  }
  doc[QStringLiteral("layers")] = layers;
  doc[QStringLiteral("_pathHints")] = hints;
  return doc;
}

static QString relativeProjectPath(const QString &value, const QString &projectFile) {
  if (value.isEmpty() || !QFileInfo(value).isAbsolute() || !QUrl(value).scheme().isEmpty()) return value;
  return QDir(QFileInfo(projectFile).absolutePath()).relativeFilePath(value);
}

static QVariantMap relativizeProjectPaths(QVariantMap doc, const QString &projectFile) {
  doc[QStringLiteral("video")] = relativeProjectPath(doc.value(QStringLiteral("video")).toString(), projectFile);
  doc[QStringLiteral("srt")] = relativeProjectPath(doc.value(QStringLiteral("srt")).toString(), projectFile);
  QVariantList layers = doc.value(QStringLiteral("layers")).toList();
  for (QVariant &value : layers) {
    QVariantMap layer = value.toMap();
    layer[QStringLiteral("path")] = relativeProjectPath(layer.value(QStringLiteral("path")).toString(), projectFile);
    value = layer;
  }
  doc[QStringLiteral("layers")] = layers;
  doc.remove(QStringLiteral("_pathHints"));
  return doc;
}

QVariantMap OmareelEngine::loadProject() {
  QFile f(projectPath());
  if (!f.open(QIODevice::ReadOnly)) return {};
  const QByteArray bytes = f.readAll();
  m_lastProjHash = QCryptographicHash::hash(bytes, QCryptographicHash::Sha1);
  watchProjectFile();
  const QJsonDocument d = QJsonDocument::fromJson(bytes);
  return d.isObject() ? resolveProjectPaths(d.object().toVariantMap(), projectPath()) : QVariantMap{};
}

static bool writeProjectFile(const QString &path, const QVariantMap &doc, QByteArray *hash) {
  const QByteArray bytes = QJsonDocument::fromVariant(doc).toJson(QJsonDocument::Indented);
  if (!QDir().mkpath(QFileInfo(path).absolutePath())) return false;
  QSaveFile f(path);
  if (!f.open(QIODevice::WriteOnly) || f.write(bytes) != bytes.size() || !f.commit()) return false;
  if (hash) *hash = QCryptographicHash::hash(bytes, QCryptographicHash::Sha1);
  return true;
}

bool OmareelEngine::saveProject(const QVariantMap &doc) {
  QByteArray hash;
  if (!writeProjectFile(projectPath(), doc, &hash)) return false;
  m_lastProjHash = hash;
  watchProjectFile();
  return true;
}

QVariantMap OmareelEngine::openProjectFile(const QString &fileUrl) {
  const QUrl url(fileUrl);
  const QString file = url.isLocalFile() ? url.toLocalFile() : fileUrl;
  QFile f(file);
  if (!f.open(QIODevice::ReadOnly)) return {};
  const QByteArray bytes = f.readAll();
  const QJsonDocument d = QJsonDocument::fromJson(bytes);
  if (!d.isObject() || !setProjectFile(file)) return {};
  m_lastProjHash = QCryptographicHash::hash(bytes, QCryptographicHash::Sha1);
  return resolveProjectPaths(d.object().toVariantMap(), file);
}

bool OmareelEngine::saveProjectAs(const QString &fileUrl, const QVariantMap &doc) {
  const QUrl url(fileUrl);
  const QString file = url.isLocalFile() ? url.toLocalFile() : fileUrl;
  if (file.isEmpty()) return false;
  const QString target = QFileInfo(file).absoluteFilePath();
  QByteArray hash;
  if (!writeProjectFile(target, relativizeProjectPaths(doc, target), &hash)) return false;
  m_lastProjHash = hash;
  return setProjectFile(target);
}
