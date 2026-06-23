use v5.36;
use Test2::V0;
use App::PerlGraph::Format;

# Format::changelog renders a Changes-style draft from the structural-diff shape that
# App::PerlGraph::Diff->diff returns. Drive it directly with synthetic diffs (the diff
# itself is covered by the diff/semver tests).
my $d = {
    added   => [ { qualified_name => 'P::new_pub', kind => 'function', signature => '($x)' },
                 { qualified_name => 'P::_helper', kind => 'function', visibility => 'private' } ],
    removed => [ { qualified_name => 'P::gone',    kind => 'method', visibility => 'public', _breaking => 1 } ],
    changed => [ { old => { signature => '($a)' },
                   new => { qualified_name => 'P::resig', kind => 'function', signature => '($a, $b)' },
                   _breaking => 1 } ],
};
my $txt = App::PerlGraph::Format::changelog($d, 'v1.0.0');
like $txt, qr/Draft changelog \(vs v1\.0\.0\)/,                 'header names the ref';
like $txt, qr/Suggested version bump: \*\*major\*\*/,          'a breaking change -> major bump';
like $txt, qr/### Added.*P::new_pub/s,                         'lists an added public symbol';
like $txt, qr/P::_helper.*internal/,                           'a private addition is tagged internal';
like $txt, qr/### Removed.*P::gone.*breaking/s,                'a removed public symbol is flagged breaking';
like $txt, qr/### Changed.*P::resig.*\(\$a\).*->.*\(\$a, \$b\).*breaking/s, 'a re-signatured symbol shows old -> new';
like $txt, qr/edit into prose/,                                'reminds you it is a draft';

like App::PerlGraph::Format::changelog(
    { added => [{ qualified_name => 'P::feat', kind => 'function' }], removed => [], changed => [] }, 'main'),
    qr/bump: \*\*minor\*\*/, 'a new public symbol only -> minor';
like App::PerlGraph::Format::changelog(
    { added => [{ qualified_name => 'P::_x', kind => 'function', visibility => 'private' }], removed => [], changed => [] }, 'main'),
    qr/bump: \*\*patch\*\*/, 'a private-only addition -> patch';
like App::PerlGraph::Format::changelog({ added => [], removed => [], changed => [] }, 'main'),
    qr/no structural changes/, 'an empty diff renders cleanly';

done_testing;
