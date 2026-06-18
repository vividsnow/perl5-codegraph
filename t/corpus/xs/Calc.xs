#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

MODULE = Acme::Calc    PACKAGE = Acme::Calc

int
add(a, b)
    int a
    int b
  CODE:
    RETVAL = a + b;
  OUTPUT:
    RETVAL

double
square(x)
    double x
  CODE:
    RETVAL = x * x;
  OUTPUT:
    RETVAL
