use v5.36;
use Test2::V0;
use App::PerlGraph;
like $App::PerlGraph::VERSION, qr/\A\d+\.\d+/, 'VERSION is a dotted version string';
done_testing;
