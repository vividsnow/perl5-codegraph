package Foo;
use Foo::Bar;
sub run { Foo::Bar::help(); shout() }
sub shout { "FOO" }
1;
