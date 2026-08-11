// Minimal geometry value types (CGFloat/CGRect stand-ins). Bar-local
// coordinates are top-left-origin, y-down throughout — Windows-native.

#pragma once

#include <algorithm>

namespace ybar::model {

struct Point {
    double x = 0;
    double y = 0;
    bool operator==(const Point&) const = default;
};

struct Size {
    double width = 0;
    double height = 0;
    bool operator==(const Size&) const = default;
};

struct Rect {
    double x = 0;
    double y = 0;
    double width = 0;
    double height = 0;

    double minX() const { return x; }
    double minY() const { return y; }
    double maxX() const { return x + width; }
    double maxY() const { return y + height; }
    double midX() const { return x + width / 2; }
    double midY() const { return y + height / 2; }
    bool isEmpty() const { return width <= 0 || height <= 0; }
    bool isZero() const { return x == 0 && y == 0 && width == 0 && height == 0; }

    bool contains(Point p) const {
        return p.x >= minX() && p.x < maxX() && p.y >= minY() && p.y < maxY();
    }

    Rect unionWith(const Rect& o) const {
        if (isEmpty()) return o;
        if (o.isEmpty()) return *this;
        const double nx = std::min(minX(), o.minX());
        const double ny = std::min(minY(), o.minY());
        return Rect{nx, ny, std::max(maxX(), o.maxX()) - nx, std::max(maxY(), o.maxY()) - ny};
    }

    Rect intersect(const Rect& o) const {
        const double nx = std::max(minX(), o.minX());
        const double ny = std::max(minY(), o.minY());
        const double nw = std::min(maxX(), o.maxX()) - nx;
        const double nh = std::min(maxY(), o.maxY()) - ny;
        if (nw <= 0 || nh <= 0) return Rect{};
        return Rect{nx, ny, nw, nh};
    }

    Rect insetBy(double dx, double dy) const {
        return Rect{x + dx, y + dy, width - 2 * dx, height - 2 * dy};
    }

    bool operator==(const Rect&) const = default;
};

} // namespace ybar::model
