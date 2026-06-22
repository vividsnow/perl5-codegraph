use v5.36;
use Test2::V0;
use App::PerlGraph::Format;

# --- classification logic, exercised directly on synthetic diffs ---

# MAJOR: a removed (or re-signatured) PUBLIC symbol
my $major = { added => [], changed => [],
    removed => [{ qualified_name => 'A::gone', kind => 'function', _breaking => 1 }] };
like App::PerlGraph::Format::semver($major, 'v1'), qr/Recommended bump: MAJOR/, 'removed public API -> MAJOR';
like App::PerlGraph::Format::semver($major, 'v1'), qr/removed `A::gone`/,        'lists the breaking removal';

my $major2 = { added => [], removed => [], changed => [
    { old => { qualified_name => 'A::f', signature => '($x)' },
      new => { qualified_name => 'A::f', kind => 'function', signature => '($x, $y)' }, _breaking => 1 } ] };
like App::PerlGraph::Format::semver($major2, 'v1'), qr/MAJOR/,           're-signatured public sub -> MAJOR';
like App::PerlGraph::Format::semver($major2, 'v1'), qr/re-signatured `A::f`/, 'lists the re-signature';

# MINOR: new public API, nothing breaking (no visibility == public)
my $minor = { removed => [], changed => [],
    added => [{ qualified_name => 'A::shiny', kind => 'function' }] };
like App::PerlGraph::Format::semver($minor, 'v1'), qr/Recommended bump: MINOR/, 'new public API -> MINOR';
like App::PerlGraph::Format::semver($minor, 'v1'), qr/\+ `A::shiny`/,           'lists the new public symbol';

# PATCH: only private additions / non-breaking internal changes
my $patch = { removed => [],
    added   => [{ qualified_name => 'A::_helper', kind => 'function', visibility => 'private' }],
    changed => [{ new => { qualified_name => 'A::_p', kind => 'function' }, _breaking => 0 }] };
like App::PerlGraph::Format::semver($patch, 'v1'), qr/Recommended bump: PATCH/, 'internal-only -> PATCH';
like App::PerlGraph::Format::semver($patch, 'v1'), qr/internal . non-public change/, 'notes the internal changes';

# --- end-to-end through the real Diff pipeline (git) ---
SKIP: {
    skip "git unavailable", 1 unless eval { my $v = `git --version 2>/dev/null`; $? == 0 && $v =~ /git/ };
    my $parser = eval { App::PerlGraph::Parser->new } or skip "parser unavailable", 1;
    eval { $parser->parse_string("1;\n") } or skip "grammar not built", 1;
    require App::PerlGraph::Diff;
    require Path::Tiny;
    my $dir = Path::Tiny->tempdir; $dir->child('lib')->mkpath;
    my @gc = ('git', '-C', "$dir");
    $dir->child('lib/A.pm')->spew_utf8("package A;\nsub keep { 1 }\nsub gone { 2 }\n1;\n");
    system @gc, 'init', '-q'; system @gc, 'config', 'user.email', 't@t'; system @gc, 'config', 'user.name', 't';
    system @gc, 'add', '-A'; system @gc, 'commit', '-qm', 'v1';
    $dir->child('lib/A.pm')->spew_utf8("package A;\nsub keep { 1 }\n1;\n");   # remove the public A::gone
    my $d = App::PerlGraph::Diff->new(root => "$dir", ref => 'HEAD', parser => $parser)->diff;
    like App::PerlGraph::Format::semver($d, 'HEAD'), qr/MAJOR/, 'removing a public sub (real git diff) -> MAJOR';
}

done_testing;
