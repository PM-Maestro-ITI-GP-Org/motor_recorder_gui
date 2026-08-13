#include "traceview.h"

#include <QSGGeometryNode>
#include <QSGGeometry>
#include <QSGFlatColorMaterial>
#include <QStringView>
#include <cmath>

TraceView::TraceView(QQuickItem *parent) : QQuickItem(parent)
{
    setFlag(ItemHasContents, true);
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

        for (int i = 0; i < points; ++i) {
            const int r = qMin(r1 - 1, r0 + i * step);
            const float x = float(r - r0) / float(span) * float(w);
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
