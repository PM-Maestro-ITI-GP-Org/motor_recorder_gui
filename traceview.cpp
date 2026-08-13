#include "traceview.h"

#include <QSGGeometryNode>
#include <QSGGeometry>
#include <QSGFlatColorMaterial>
#include <QStringView>
#include <cmath>
#include <QFile>
#include <QByteArray>
#include <thread>
#include <functional>

TraceView::TraceView(QQuickItem *parent) : QQuickItem(parent)
{
    setFlag(ItemHasContents, true);
}


/*
 * Parse CSV bytes into float columns.
 *
 * Works on raw bytes rather than a QString: a 196MB file becomes ~392MB as
 * UTF-16, and every field would be converted twice. CSV here is ASCII digits
 * and commas, so bytes are the natural unit and strtof is handed the buffer
 * directly.
 *
 * `report` is called with 0..1 occasionally; it must be safe to call from a
 * worker thread. `cancelled` lets a superseded load stop early instead of
 * finishing work whose result will be thrown away.
 */
static bool parseCsvBytes(const QByteArray &buf,
                          QVector<QVector<float>> &cols,
                          QStringList &headers,
                          const std::function<void(qreal)> &report,
                          const std::function<bool()> &cancelled)
{
    const char *p = buf.constData();
    const qsizetype n = buf.size();
    if (n <= 0) return false;

    qsizetype i = 0, ls = 0;
    while (i < n && p[i] != '\n') ++i;
    qsizetype le = i;
    if (le > ls && p[le - 1] == '\r') --le;

    for (qsizetype fs = ls, k = ls; k <= le; ++k) {
        if (k == le || p[k] == ',') {
            headers << QString::fromLatin1(p + fs, int(k - fs)).trimmed();
            fs = k + 1;
        }
    }
    const int nCols = headers.size();
    if (nCols == 0) return false;

    cols.resize(nCols);
    const int guess = int(qMax<qsizetype>(1024, n / qMax(1, nCols * 8)));
    for (int c = 0; c < nCols; ++c)
        cols[c].reserve(guess);

    ++i;
    qsizetype lastReport = 0;

    while (i < n) {
        if (cancelled && cancelled()) return false;

        ls = i;
        while (i < n && p[i] != '\n') ++i;
        le = i;
        if (le > ls && p[le - 1] == '\r') --le;
        ++i;
        if (le <= ls) continue;

        int col = 0;
        qsizetype fs = ls;
        for (qsizetype k = ls; k <= le && col < nCols; ++k) {
            if (k == le || p[k] == ',') {
                cols[col].append(strtof(p + fs, nullptr));
                ++col;
                fs = k + 1;
            }
        }
        for (; col < nCols; ++col)
            cols[col].append(0.0f);

        /* Every ~4MB: often enough for a bar to move, rare enough not to be
           the cost itself. */
        if (report && i - lastReport > (4 << 20)) {
            lastReport = i;
            report(qreal(i) / qreal(n));
        }
    }
    if (report) report(1.0);
    return true;
}

/*
 * Parse once, into floats.
 *
 * Deliberately a manual scan rather than QString::split(',') per line: split
 * allocates a QStringList and a QString per field, which for a few hundred
 * thousand rows is millions of allocations for values that are about to become
 * floats anyway. This walks the buffer and converts each field in place.
 */
int TraceView::loadCsvText(const QString &text)
{
    clearData();
    if (text.isEmpty())
        return 0;

    const QChar *p = text.constData();
    const int n = text.size();

    /* ---- header ---- */
    int i = 0, lineStart = 0;
    while (i < n && p[i] != QLatin1Char('\n')) ++i;
    int lineEnd = i;
    if (lineEnd > lineStart && p[lineEnd - 1] == QLatin1Char('\r')) --lineEnd;

    {
        int fs = lineStart;
        for (int k = lineStart; k <= lineEnd; ++k) {
            if (k == lineEnd || p[k] == QLatin1Char(',')) {
                m_headers << QString(p + fs, k - fs).trimmed();
                fs = k + 1;
            }
        }
    }
    const int nCols = m_headers.size();
    if (nCols == 0)
        return 0;

    m_cols.resize(nCols);
    /* One growth up front rather than per row. A rough guess is fine: too
       small only costs the usual doubling, too large costs one shrink. */
    const int guess = qMax(1024, n / qMax(1, nCols * 8));
    for (int c = 0; c < nCols; ++c)
        m_cols[c].reserve(guess);

    ++i;   /* past the header newline */

    /* ---- rows ---- */
    while (i < n) {
        lineStart = i;
        while (i < n && p[i] != QLatin1Char('\n')) ++i;
        lineEnd = i;
        if (lineEnd > lineStart && p[lineEnd - 1] == QLatin1Char('\r')) --lineEnd;
        ++i;

        if (lineEnd <= lineStart)
            continue;                       /* blank line */

        int col = 0, fs = lineStart;
        for (int k = lineStart; k <= lineEnd && col < nCols; ++k) {
            if (k == lineEnd || p[k] == QLatin1Char(',')) {
                bool ok = false;
                const float v = QStringView(p + fs, k - fs).toFloat(&ok);
                m_cols[col].append(ok ? v : 0.0f);
                ++col;
                fs = k + 1;
            }
        }
        /* Short row: pad, so every column stays the same length and the draw
           loop never has to bounds-check per point. */
        for (; col < nCols; ++col)
            m_cols[col].append(0.0f);
    }

    m_rows = m_cols.isEmpty() ? 0 : m_cols[0].size();

    m_xMin = 0;
    m_xMax = m_rows > 0 ? m_rows : 1;
    m_yMin = m_yMax = qQNaN();

    emit dataChanged();
    emit windowChanged();
    update();
    return m_rows;
}


void TraceView::installColumns(QVector<QVector<float>> cols, QStringList headers)
{
    m_cols = std::move(cols);
    m_headers = std::move(headers);
    m_rows = m_cols.isEmpty() ? 0 : m_cols[0].size();
    m_xMin = 0;
    m_xMax = m_rows > 0 ? m_rows : 1;
    m_yMin = m_yMax = qQNaN();
    emit dataChanged();
    emit windowChanged();
    update();
}

void TraceView::loadCsvFileAsync(const QString &path)
{
    const quint64 seq = ++m_loadSeq;

    m_progress = 0;
    m_loading = true;
    emit loadProgressChanged();
    emit loadingChanged();

    /*
     * Detached, with the sequence number as the guard.
     *
     * Everything the thread touches is either its own local or marshalled back
     * with a queued call, so the render thread never sees a half-built column.
     * A load that is superseded (the user picks another file mid-parse) sees a
     * bumped m_loadSeq and drops its result rather than racing the newer one.
     */
    std::thread([this, path, seq]() {
        QVector<QVector<float>> cols;
        QStringList headers;
        bool ok = false;

        QFile f(path);
        if (f.open(QIODevice::ReadOnly)) {
            const QByteArray buf = f.readAll();
            f.close();
            ok = parseCsvBytes(
                buf, cols, headers,
                [this, seq](qreal frac) {
                    QMetaObject::invokeMethod(this, [this, seq, frac]() {
                        if (seq != m_loadSeq) return;
                        m_progress = frac;
                        emit loadProgressChanged();
                    }, Qt::QueuedConnection);
                },
                [this, seq]() { return seq != m_loadSeq; });
        }

        QMetaObject::invokeMethod(this,
            [this, seq, ok, c = std::move(cols), h = std::move(headers)]() mutable {
                if (seq != m_loadSeq) return;      /* superseded */
                if (ok) installColumns(std::move(c), std::move(h));
                m_loading = false;
                m_progress = 1.0;
                emit loadingChanged();
                emit loadProgressChanged();
                emit loadFinished(ok ? m_rows : 0);
            }, Qt::QueuedConnection);
    }).detach();
}

void TraceView::clearData()
{
    m_cols.clear();
    m_headers.clear();
    m_rows = 0;
    m_xMin = 0; m_xMax = 1;
    m_yMin = m_yMax = qQNaN();
    emit dataChanged();
    update();
}

qreal TraceView::timeAt(int row) const
{
    if (m_cols.isEmpty() || row < 0 || row >= m_cols[0].size()) return 0;
    return m_cols[0][row];
}

/* Column 0 is microseconds on the wire (mqtt_client.c publishes the STM32
   timebase in us, and the CSV carries the same). */
qreal TraceView::visibleSeconds() const
{
    const int r0 = qMax(0, int(std::floor(m_xMin)));
    const int r1 = qMin(m_rows, int(std::ceil(m_xMax)));
    if (m_cols.isEmpty() || r1 - r0 < 2) return 0;
    const double us = double(m_cols[0][r1 - 1]) - double(m_cols[0][r0]);
    return us > 0 ? us / 1e6 : 0;
}

qreal TraceView::sampleRateHz() const
{
    const int r0 = qMax(0, int(std::floor(m_xMin)));
    const int r1 = qMin(m_rows, int(std::ceil(m_xMax)));
    const double secs = visibleSeconds();
    if (secs <= 0) return 0;
    return double(r1 - r0 - 1) / secs;
}

qreal TraceView::valueAt(int column, int row) const
{
    if (column < 0 || column >= m_cols.size()) return 0;
    if (row < 0 || row >= m_cols[column].size()) return 0;
    return m_cols[column][row];
}

/* Min/max across visible series over the current x window. */
void TraceView::resolveY(float &lo, float &hi) const
{
    if (!std::isnan(m_yMin) && !std::isnan(m_yMax) && m_yMax > m_yMin) {
        lo = float(m_yMin);
        hi = float(m_yMax);
        return;
    }

    lo =  std::numeric_limits<float>::infinity();
    hi = -std::numeric_limits<float>::infinity();

    const int r0 = qMax(0, int(std::floor(m_xMin)));
    const int r1 = qMin(m_rows, int(std::ceil(m_xMax)));

    /* Sample rather than scan every row: the bounds only feed axis labels and
       the vertical fit, and one sample per horizontal pixel is already finer
       than anything that can be seen. */
    const int want = qMax(1, int(width()));
    const int step = qMax(1, (r1 - r0) / want);

    for (int c = 1; c < m_cols.size(); ++c) {
        if (c >= m_visible.size() || !m_visible[c].toBool()) continue;
        const QVector<float> &col = m_cols[c];
        for (int r = r0; r < r1; r += step) {
            const float v = col[r];
            if (v < lo) lo = v;
            if (v > hi) hi = v;
        }
    }

    if (!std::isfinite(lo) || !std::isfinite(hi)) { lo = 0.f; hi = 1000.f; }
    float pad = (hi - lo) * 0.1f;
    if (pad <= 0.f) pad = 1.f;
    lo -= pad; hi += pad;
}

QVariantList TraceView::visibleYBounds() const
{
    float lo, hi;
    resolveY(lo, hi);
    return QVariantList{ lo, hi };
}

void TraceView::setXMin(qreal v) { if (m_xMin != v) { m_xMin = v; emit windowChanged(); update(); } }
void TraceView::setXMax(qreal v) { if (m_xMax != v) { m_xMax = v; emit windowChanged(); update(); } }
void TraceView::setYMin(qreal v) { m_yMin = v; emit windowChanged(); update(); }
void TraceView::setYMax(qreal v) { m_yMax = v; emit windowChanged(); update(); }

void TraceView::setSeriesVisible(const QVariantList &v)
{
    m_visible = v; emit seriesChanged(); update();
}
void TraceView::setSeriesColors(const QVariantList &v)
{
    m_colors = v; emit seriesChanged(); update();
}

/*
 * Build one line strip per visible series.
 *
 * Runs on the render thread with the GUI thread blocked, so reading the column
 * data here without a lock is safe -- it is only ever replaced from the GUI
 * thread in loadCsvText().
 *
 * Nodes are reused across frames where possible: allocating a QSGGeometryNode
 * per series per frame would hand the scene graph a completely new subtree
 * every time the mouse moves.
 */
QSGNode *TraceView::updatePaintNode(QSGNode *oldNode, UpdatePaintNodeData *)
{
    QSGNode *root = oldNode;
    if (!root)
        root = new QSGNode;

    const int w = int(width());
    const int h = int(height());
    if (w <= 0 || h <= 0 || m_rows < 2) {
        while (root->childCount())
            delete root->childAtIndex(0);
        return root;
    }

    const int r0 = qMax(0, int(std::floor(m_xMin)));
    const int r1 = qMin(m_rows, int(std::ceil(m_xMax)));
    const int span = qMax(1, r1 - r0);

    float lo, hi;
    resolveY(lo, hi);
    const float yRange = (hi > lo) ? (hi - lo) : 1.f;

    /* At most one vertex per horizontal pixel: more cannot be distinguished,
       and every extra one is uploaded to the GPU each frame. */
    const int step   = qMax(1, span / qMax(1, w));
    const int points = qMax(2, (span + step - 1) / step);

    /* Column 0 is the timebase when it is present and monotonic; if it is
       not, fall back to index spacing rather than drawing nonsense. */
    const QVector<float> *tsCol = nullptr;
    if (!m_cols.isEmpty() && m_cols[0].size() == m_rows
        && m_cols[0][r1 - 1] > m_cols[0][r0])
        tsCol = &m_cols[0];

    int childIdx = 0;
    for (int c = 1; c < m_cols.size(); ++c) {
        if (c >= m_visible.size() || !m_visible[c].toBool()) continue;

        QColor colour = (c < m_colors.size()) ? m_colors[c].value<QColor>()
                                              : QColor(Qt::black);

        QSGGeometryNode *node = nullptr;
        if (childIdx < root->childCount()) {
            node = static_cast<QSGGeometryNode *>(root->childAtIndex(childIdx));
        } else {
            node = new QSGGeometryNode;
            auto *g = new QSGGeometry(QSGGeometry::defaultAttributes_Point2D(), points);
            g->setDrawingMode(QSGGeometry::DrawLineStrip);
            g->setLineWidth(1.6f);
            node->setGeometry(g);
            node->setFlag(QSGNode::OwnsGeometry, true);
            auto *m = new QSGFlatColorMaterial;
            node->setMaterial(m);
            node->setFlag(QSGNode::OwnsMaterial, true);
            root->appendChildNode(node);
        }

        QSGGeometry *g = node->geometry();
        if (g->vertexCount() != points)
            g->allocate(points);

        QSGGeometry::Point2D *v = g->vertexDataAsPoint2D();
        const QVector<float> &col = m_cols[c];

        /*
         * X comes from the timestamp column, not from the row index.
         *
         * Plotting against the index assumes every row is equally spaced in
         * time. They are not: the producer streams blocks off SPI and a
         * dropped or delayed block leaves a real gap, so index-space drew
         * those samples as adjacent and silently compressed the gap away.
         * Zoomed out that is invisible; zoomed in to a few dozen rows it is
         * the whole picture, and the shape on screen is not the shape of the
         * signal. Using the timestamps puts each sample where it actually
         * happened, and the spacing then carries the true rate.
         */
        const double t0 = tsCol ? double((*tsCol)[r0])     : double(r0);
        const double t1 = tsCol ? double((*tsCol)[r1 - 1]) : double(r1 - 1);
        const double tSpan = (t1 > t0) ? (t1 - t0) : double(qMax(1, span));

        for (int i = 0; i < points; ++i) {
            const int r = qMin(r1 - 1, r0 + i * step);
            const double tv = tsCol ? double((*tsCol)[r]) : double(r);
            const float x = float((tv - t0) / tSpan) * float(w);
            const float y = float(h) * (1.f - (col[r] - lo) / yRange);
            v[i].set(x, y);
        }

        g->markVertexDataDirty();
        auto *mat = static_cast<QSGFlatColorMaterial *>(node->material());
        if (mat->color() != colour) {
            mat->setColor(colour);
            node->markDirty(QSGNode::DirtyMaterial);
        }
        node->markDirty(QSGNode::DirtyGeometry);
        ++childIdx;
    }

    /* Drop nodes for series that were switched off. */
    while (root->childCount() > childIdx)
        delete root->childAtIndex(root->childCount() - 1);

    return root;
}
