use v6;

unit class Getopt::Long;

role Converter {
	method convert($) { ... }
}

class NullConverter does Converter {
	method convert(Str:D $value) {
		return $value;
	}
}

class IntConverter does Converter {
	method convert(Str:D $value) {
		return $value.Int;
	}
}
class MaybeIntConverter does Converter {
	proto method convert(Str:D) { * }
	multi method convert(Str:D $value) {
		return $value;
	}
	multi method convert(Str:D $value where / ^ '-'? \d+ $/) {
		return IntStr($value.Int, $value);
	}
}

role Parser {
	has Str:D $.name is required;
	method takes-argument(--> Bool:D) { ... }
	method parse($raw, $others) { ... }
}

class BooleanParser does Parser {
	has Bool:D $.negatable = True;
	method takes-argument(--> Bool:D) {
		return False;
	}
	method parse(Str $raw, $) {
		my $name = $!name;
		if $raw eq $!name {
			return True;
		}
		elsif $!negatable && $raw ~~ / ^ 'no' '-'? $name $/ {
			return False
		}
		else {
			die "$raw can't match boolean {$name}?";
		}
	}
}

class ArgumentedParser does Parser {
	has Converter $.converter = NullConverter;
	method takes-argument(--> Bool) {
		return True;
	}
	method parse(Str:D $raw, Array:D $others) {
		my $name = self.name;
		if $raw eq $!name {
			if $others.elems {
				return $!converter.convert($others.shift);
			}
			else {
				die "Expected an argument";
			}
		}
		elsif $raw ~~ / ^ $name '=' $<value>=[.*] / -> $/ {
			return $!converter.convert(~$<value>);
		}
		else {
			die "$raw can't match argument {$name.perl}?";
		}
	}
}

role Multiplexer {
	has Str:D $.key is required;
	has Any:U $.type = Any;
	method store($value, $hash) { ... }
}

class Monoplexer does Multiplexer {
	method store(Any:D $value, Hash:D $hash) {
		$hash{$!key} = $value;
	}
}

class Arrayplexer does Multiplexer {
	method store(Any:D $value, Hash:D $hash) {
		$hash{$!key} //= Array[$!type].new;
		$hash{$!key}.push($value);
	}
}

class Hashplexer does Multiplexer {
	method store(Any:D $pair, Hash:D $hash) {
		my ($key, $value) = $pair.split('=', 2);
		$hash{$!key} //= Hash[$!type].new;
		$hash{$!key}{$key} = $value;
	}
}

class Option {
	has Parser:D $.parser is required handles <name takes-argument>;
	has Multiplexer:D $.multiplexer is required;
	method match(Str:D $raw, Any:D $arg, Hash:D $hash) {
		$!multiplexer.store($!parser.parse($raw, $arg), $hash);
	}
}

has Bool:D $.gnu-style is required;
has Bool:D $.permute is required;
has Option:D %!options is required;

submethod BUILD(:$!gnu-style, :$!permute, :%!options) { }

my regex names {
	[ $<name>=[\w+] ]+ % '|'
	{ make @<name>».Str.list }
}
multi parse-option(Str $pattern where rx/ ^ <names> $<negatable>=['!'?] $ /) {
	my $multiplexer = Monoplexer.new(:key($<names>.made[0]));
	return $<names>.made.map: -> $name {
		Option.new(:$multiplexer, parser => BooleanParser.new(:$name, :negatable(?$<negatable>)));
	}
}

my %multiplexer-for = (
	'%' => Hashplexer,
	'@' => Arrayplexer,
	''  => Monoplexer,
	'$' => Monoplexer,
);

multi parse-option(Str $pattern where rx/ ^ <names> '=' $<type>=<[si]> $<class>=[<[%@]>?] /) {
	my ($converter, $type) = $<type> eq 'i' ?? (IntConverter, Int) !! (NullConverter, Str);
	my $multiplexer = %multiplexer-for{~$<class>}.new(:key($<names>.made[0]), :$type);
	$<names>.made.map: -> $name {
		Option.new(:$multiplexer, parser => ArgumentedParser.new(:$name, :$converter));
	}
}

multi parse-option(Str $pattern) {
	die "Invalid pattern '$pattern'";
}

my %converter-for{Any:U} = (
	(Int) => IntConverter,
	(Str) => NullConverter,
	(Any) => MaybeIntConverter,
);

sub parse-parameter(Parameter $param) {
	my ($key) = my @names = $param.named_names;
	my $type = $param.sigil eq '$' ?? $param.type !! $param.type.of;
	my $converter = %converter-for{$type} // NullConverter;
	my $multiplexer = %multiplexer-for{$param.sigil}.new(:$key, :$type);
	my $parser = $param.sigil eq '$' && $param.type === Bool ?? BooleanParser !! ArgumentedParser;
	return @names.map: -> $name {
		Option.new(:$multiplexer, parser => $parser.new(:$name, :$converter));
	}
}

multi method new(Sub $main, Bool:D :$gnu-style = True, Bool:D :$permute = False) {
	my %options;
	if $main.multi {
		for $main.candidates -> $candidates {
			for $main.signature.params.grep(*.named) -> $param {
				for parse-parameter($param) -> $option {
					if %options{$option.name}:exists and %options{$option.name} !eqv $option {
						die "Can't merge arguments for {$option.name}";
					}
					%options{$option.name} = $option;
				}
			}
		}
	}
	else {
		for $main.signature.params.grep(*.named) -> $param {
			for parse-parameter($param) -> $option {
				%options{$option.name} = $option;
			}
		}
	}
	return self.bless(:$gnu-style, :$permute, :%options);
}
multi method new(*@patterns, Bool:D :$gnu-style = True, Bool:D :$permute = False) {
	my %options;
	for @patterns -> $pattern {
		for parse-option($pattern) -> $option {
			%options{$option.name} = $option;
		}
	}
	return self.bless(:$gnu-style, :$permute, :%options);
}

method get-options(@argv) {
	my @args = @argv;
	my (@list, %hash);
	while @args {
		my $head = @args.shift;
		if $head ~~ / ^ '--' $<name>=[\w+] $ / -> $/ {
			if %!options{$<name>} -> $option {
				$option.match(~$<name>, @args, %hash);
			}
			else {
				die "Unknown option $<name>: ";
			}
		}
		elsif $!gnu-style && $head ~~ / ^ '--' $<value>=[ $<name>=[\w+] '=' .* ] / -> $/ {
			if %!options{$<name>} -> $option {
				die "Option {$option.name} doesn't take arguments" unless $option.takes-argument;
				$option.match(~$<value>, @args, %hash);
			}
			else {
				die "Unknown option $<name>";
			}
		}
		else {
			if $!permute {
				@list.push: $head;
			}
			else {
				@list.append: $head, |@args;
				last;
			}
		}
	}
	return \(|@list, |%hash);
}

our sub MAIN_HELPER($retval = 0) is export {
	my &m = callframe(1).my<&MAIN>;
	return $retval unless &m;
	m(|Getopt::Long.new(&m).get-options(@*ARGS));
}
