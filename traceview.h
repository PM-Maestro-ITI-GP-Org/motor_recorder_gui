#ifndef TRACEVIEW_H
#define TRACEVIEW_H

#include <QQuickItem>
#include <QVector>
#include <QStringList>
#include <QColor>
#include <QVariantList>

/*
 * GPU-rendered multi-series line plot.
 *
 * Replaces a Canvas whose onPaint walked a JS array of arrays of STRINGS and
 * called Number() on each cell -- twice per frame, once to find the Y range and
 * once to draw. At 2000 points across 13 columns that is ~52k string-to-float
 * conversions per repaint, and zoom and pan repaint continuously, so the cost
 * was paid on every mouse move. Canvas also rasterises on the CPU into a
 * texture that is then uploaded, so the drawing itself was never on the GPU
 * either.
 *
 * Here the file is parsed once into float columns, and each visible series
 * becomes a QSGGeometryNode of GL_LINE_STRIP vertices handed to Qt's scene
 * graph -- which uploads them and draws them with the hardware. Changing the
 * zoom window rebuilds vertex positions for at most one point per horizontal
 * pixel and touches no strings at all.
 */
class TraceView : public QQuickItem
{
    Q_OBJECT

    /* Visible row window (x axis). */
    Q_PROPERTY(qreal xMin READ xMin WRITE setXMin NOTIFY windowChanged)
    Q_PROPERTY(qreal xMax READ xMax WRITE setXMax NOTIFY windowChanged)

    /* Visible value window (y axis). NaN on either side means autoscale to
       whatever is in the current x window. */
    Q_PROPERTY(qreal yMin READ yMin WRITE setYMin NOTIFY windowChanged)
    Q_PROPERTY(qreal yMax READ yMax WRITE setYMax NOTIFY windowChanged)

    /* One bool per column; column 0 is the timestamp and is never drawn. */
    Q_PROPERTY(QVariantList seriesVisible READ seriesVisible
               WRITE setSeriesVisible NOTIFY seriesChanged)
    /* One colour per column, indexed the same way. */
    Q_PROPERTY(QVariantList seriesColors READ seriesColors
               WRITE setSeriesColors NOTIFY seriesChanged)

    Q_PROPERTY(int rowCount READ rowCount NOTIFY dataChanged)
    Q_PROPERTY(QStringList headers READ headers NOTIFY dataChanged)

public:
    explicit TraceView(QQuickItem *parent = nullptr);

    /* Parse CSV text into float columns. Returns row count, 0 on failure.
       Everything downstream works on floats; no string survives this call. */
    Q_INVOKABLE int loadCsvText(const QString &text);
    Q_INVOKABLE void clearData();

    /* Autoscaled [min, max] over the current x window, for the axis labels
       that are still drawn in QML. Empty if there is nothing visible. */
    Q_INVOKABLE QVariantList visibleYBounds() const;

    /* Row index <-> value, so the QML mouse handlers can convert a pixel. */
    Q_INVOKABLE qreal valueAt(int column, int row) const;

    /* The timestamp of a row, in whatever units column 0 carries (the
       recorder writes microseconds). The axis is labelled from these rather
       than from row numbers -- see the note in updatePaintNode. */
    Q_INVOKABLE qreal timeAt(int row) const;
    /* Seconds spanned by the current x window, 0 if unknown. */
    Q_INVOKABLE qreal visibleSeconds() const;
    /* Mean sample rate over the current window, Hz. 0 if unknown. */
    Q_INVOKABLE qreal sampleRateHz() const;

    qreal xMin() const { return m_xMin; }
    qreal xMax() const { return m_xMax; }
    qreal yMin() const { return m_yMin; }
    qreal yMax() const { return m_yMax; }
    void setXMin(qreal v);
    void setXMax(qreal v);
    void setYMin(qreal v);
    void setYMax(qreal v);

    QVariantList seriesVisible() const { return m_visible; }
    QVariantList seriesColors() const { return m_colors; }
    void setSeriesVisible(const QVariantList &v);
    void setSeriesColors(const QVariantList &v);

    int rowCount() const { return m_rows; }
    QStringList headers() const { return m_headers; }

signals:
    void windowChanged();
    void seriesChanged();
    void dataChanged();

protected:
    QSGNode *updatePaintNode(QSGNode *oldNode, UpdatePaintNodeData *) override;

private:
    /* Column-major: m_cols[c][r]. Column-major because a draw pass walks one
       series at a time, so this is the order it is read in. */
    QVector<QVector<float>> m_cols;
    QStringList   m_headers;
    int           m_rows = 0;

    qreal m_xMin = 0, m_xMax = 1;
    qreal m_yMin = qQNaN(), m_yMax = qQNaN();
    QVariantList m_visible;
    QVariantList m_colors;

    void resolveY(float &lo, float &hi) const;
};

#endif
