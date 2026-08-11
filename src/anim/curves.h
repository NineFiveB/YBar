// Animation easing curves (docs/WINDOWS-PORT.md, section 3.8). Formulas are a
// visual-parity contract with the YBar reference implementation; durations
// elsewhere are frames-at-60Hz. bounce/overshoot may exceed 1.0 (springy).

#pragma once

#include <string_view>

namespace ybar::anim {

enum class Curve { Linear, Quadratic, Sin, Tanh, Exp, Circ, Bounce, Overshoot };

// CLI names parse by FIRST letter: q/s/t/e/c/b/o; anything else is linear.
Curve parseCurve(std::string_view name);

// t in [0, 1] -> eased progress. Endpoints: apply(c, 0) == 0, apply(c, 1) == 1.
double apply(Curve curve, double t);

} // namespace ybar::anim
