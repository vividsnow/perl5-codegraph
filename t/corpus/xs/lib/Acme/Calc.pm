package Acme::Calc;
sub compute { return Acme::Calc::add(1, 2) }   # calls into the XS
1;
