// =============================================================
// fixed_pkg.sv
// Global fixed-point format definitions for the ray tracer.
// Format: Q12.20  -> 32-bit signed, 12 integer bits, 20 fraction bits
// =============================================================
package fixed_pkg;
    parameter int FIXED_WIDTH = 32;
    parameter int FRAC_BITS   = 20;
    parameter int INT_BITS    = FIXED_WIDTH - FRAC_BITS; // 12

    typedef logic signed [FIXED_WIDTH-1:0] fixed_t;

    parameter fixed_t FIXED_ONE  = fixed_t'(1 <<< FRAC_BITS);
    parameter fixed_t FIXED_ZERO = fixed_t'(0);
    parameter fixed_t FIXED_HALF = fixed_t'(1 <<< (FRAC_BITS-1));

    function automatic fixed_t to_fixed(real r);
        return fixed_t'(r * (2.0 ** FRAC_BITS));
    endfunction

    function automatic real to_real(fixed_t f);
        return real'(f) / (2.0 ** FRAC_BITS);
    endfunction
endpackage
