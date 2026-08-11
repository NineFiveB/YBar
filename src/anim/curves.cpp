#include "anim/curves.h"

#include <cmath>
#include <numbers>

namespace ybar::anim {

Curve parseCurve(std::string_view name) {
    if (name.empty()) return Curve::Linear;
    switch (name.front()) {
        case 'q': return Curve::Quadratic;
        case 's': return Curve::Sin;
        case 't': return Curve::Tanh;
        case 'e': return Curve::Exp;
        case 'c': return Curve::Circ;
        case 'b': return Curve::Bounce;
        case 'o': return Curve::Overshoot;
        default: return Curve::Linear;
    }
}

double apply(Curve curve, double t) {
    switch (curve) {
        case Curve::Linear:
            return t;
        case Curve::Quadratic:
            return t * t;
        case Curve::Sin:
            return std::sin(std::numbers::pi * t / 2.0);
        case Curve::Tanh:
            return 0.52 * std::tanh(2.0 * std::atanh(1.0 / 1.04) * (t - 0.5)) + 0.5;
        case Curve::Exp:
            return t * std::exp(t - 1.0);
        case Curve::Circ:
            return std::sqrt(1.0 - (t - 1.0) * (t - 1.0));
        case Curve::Bounce: {
            constexpr double n1 = 7.5625;
            constexpr double d1 = 2.75;
            if (t < 1.0 / d1) return n1 * t * t;
            if (t < 2.0 / d1) { t -= 1.5 / d1; return n1 * t * t + 0.75; }
            if (t < 2.5 / d1) { t -= 2.25 / d1; return n1 * t * t + 0.9375; }
            t -= 2.625 / d1;
            return n1 * t * t + 0.984375;
        }
        case Curve::Overshoot: {
            constexpr double s = 1.70158;
            const double u = t - 1.0;
            return 1.0 + (s + 1.0) * u * u * u + s * u * u;
        }
    }
    return t;
}

} // namespace ybar::anim
