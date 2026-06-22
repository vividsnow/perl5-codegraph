use v5.36;
use Test2::V0;
use Path::Tiny qw(tempdir path);
use App::PerlGraph::CLI;
use App::PerlGraph::Parser;

# capture helpers (assert OUTSIDE the local *STDOUT/*STDERR scope, like t/39)
my $cap     = sub ($code) { open my $fh, '>', \my $o; local *STDOUT = $fh; my $rc = $code->(); return ($rc, $o // '') };
my $cap_err = sub ($code) { open my $fh, '>', \my $o; local *STDERR = $fh; my $rc = $code->(); return ($rc, $o // '') };

# --version / version
for my $flag ('--version', 'version') {
    my ($rc, $out) = $cap->(sub { App::PerlGraph::CLI->run($flag) });
    is $rc, 0, "$flag exits 0";
    like $out, qr/pcg .*\b\d+\.\d+/, "$flag prints a version";
}

# a query BEFORE indexing: clear guidance, non-zero exit, and NO stray .pcg/
{
    my $dir = tempdir;
    my ($rc, $err) = $cap_err->(sub { App::PerlGraph::CLI->run('callers', 'Some::Func', "$dir") });
    is $rc, 1, 'query with no index -> non-zero exit';
    like $err, qr/no index/i, 'query with no index -> points at `pcg index`';
    ok !path($dir, '.pcg')->exists, 'a query never creates a stray .pcg/';
}

# pcg status: setup health + graph state
SKIP: {
    skip "grammar not built", 3 unless eval { App::PerlGraph::Parser->new->parse_string("1;\n"); 1 };
    my $dir = tempdir;

    my ($r1, $out1) = $cap->(sub { App::PerlGraph::CLI->run('status', "$dir") });
    like $out1, qr/parser: ok/,      'status reports parser/grammar health';
    like $out1, qr/not indexed yet/, 'status reports an unindexed project clearly';

    path($dir, 'X.pm')->spew("package X;\nsub a { 1 }\n1;\n");
    $cap->(sub { App::PerlGraph::CLI->run('index', "$dir") });
    my ($r2, $out2) = $cap->(sub { App::PerlGraph::CLI->run('status', "$dir") });
    like $out2, qr/graph:\s+nodes=[1-9]/, 'status reports node/edge counts once indexed';
}

# index flag validation (error paths -- rejected before any work, no grammar needed)
{
    my $dir = tempdir;
    my ($j0)  = $cap_err->(sub { App::PerlGraph::CLI->run('index', '--jobs', '0',   "$dir") });
    my ($jb)  = $cap_err->(sub { App::PerlGraph::CLI->run('index', '--jobs', 'bad', "$dir") });
    my ($msz) = $cap_err->(sub { App::PerlGraph::CLI->run('index', '--max-file-size', 'bad', "$dir") });
    is $j0,  2, 'index --jobs 0 is a usage error';
    is $jb,  2, 'index --jobs non-numeric is a usage error';
    is $msz, 2, 'index --max-file-size bad value is a usage error';
}

done_testing;
