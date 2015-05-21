/+
Author:
    Colin Grogan
    github.com/grogancolin

Description:
        Implementation of the expect tool (http://expect.sourceforge.net/) in D.

License:
        Boost Software License - Version 1.0 - August 17th, 2003

        Permission is hereby granted, free of charge, to any person or organization
        obtaining a copy of the software and accompanying documentation covered by
        this license (the "Software") to use, reproduce, display, distribute,
        execute, and transmit the Software, and to prepare derivative works of the
        Software, and to permit third-parties to whom the Software is furnished to
        do so, all subject to the following:

        The copyright notices in the Software and this entire statement, including
        the above license grant, this restriction and the following disclaimer,
        must be included in all copies of the Software, in whole or in part, and
        all derivative works of the Software, unless such copies or derivative
        works are solely in the form of machine-executable object code generated by
        a source language processor.

        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
        IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
        FITNESS FOR A PARTICULAR PURPOSE, TITLE AND NON-INFRINGEMENT. IN NO EVENT
        SHALL THE COPYRIGHT HOLDERS OR ANYONE DISTRIBUTING THE SOFTWARE BE LIABLE
        FOR ANY DAMAGES OR OTHER LIABILITY, WHETHER IN CONTRACT, TORT OR OTHERWISE,
        ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
        DEALINGS IN THE SOFTWARE.
+/

module expectapp;


version(DExpectMain){
	import docopt;
	import std.stdio : File, writefln, stdout, stderr;
	import dexpect : Expect, ExpectSink, ExpectException;
	import std.datetime : Clock;
	import pegged.grammar;
	import std.string : format, indexOf;
	import std.file : readText, exists;
	import std.algorithm : all, any, filter, each, canFind;
	import std.path : baseName;

version(Windows){
	enum isWindows=true;
	enum isLinux=false;
	enum os="win";
}
version(Posix){
	enum isWindows=false;
	enum isLinux=true;
	enum os="linux";
}

/// Usage string for docopt
	const string doc =
"dexpect
Usage:
    dexpect [-h] [-v] <file>...
Options:
    -h --help     Show this message
	-v --verbose  Show verbose output
";

	int main(string[] args){

		auto arguments = docopt.docopt(doc, args[1..$], true, "dexpect 0.0.1");
		bool verbose = arguments["--verbose"].toString.to!bool;
		if(verbose) writefln("Command line args:\n%s\n", arguments);

		auto fList = arguments["<file>"].asList;
		if(!arguments["<file>"].asList
				.all!(fName => fName.exists)){
				writefln("Error, a filename does not exist\n%s", fList.to!string);
				return 1;
		}
		import std.typecons : Tuple;
		import std.array : array;
		import std.traits;
		alias fname_text = Tuple!(string, "fname", string, "text");
		alias fname_grammar = Tuple!(string, "fname", ParseTree, "parsedGrammar");
		alias fname_handler = Tuple!(string, "fname", ScriptHandler, "handler");
		alias fname_result = Tuple!(string, "fname", bool, "result");
		auto parsedScripts = fList
			.map!(a => fname_text(a, a.readText))
			.map!(b => fname_grammar(b.fname, ScriptGrammar(b.text)));

		bool[string] results;

		foreach(script; parsedScripts){
			string fname =
			format("%s_%s.dexpectOutput",
				Clock.currTime.toISOString.stripToFirst('.'), script.fname.baseName);
			ExpectSink sink = ExpectSink([File(fname, "w")]);
			if(verbose)
				sink.addFile(stdout);
			ScriptHandler s = ScriptHandler(script.parsedGrammar.children[0]);
			s.sink = sink;
			results[script.fname] = s.run();
		}

		if(results.values.any!(a => a==true))
			writefln("----- Succesful -----");
		results.keys.filter!(key => results[key]==true)
			.each!(key => writefln("%s", key));

		if(results.values.any!(a => a==false))
			writefln("\n----- Failures -----");
		results.keys.filter!(key => results[key]==false)
			.each!(key => writefln("%s", key));

		return 0;
	}

struct ScriptHandler{
	ParseTree theScript;
	Expect expect;
	string[string] variables;
	ExpectSink sink;
	alias variables this; // referencing 'this' will now point to variables

	/**
	  * Overloads the index operators so when "timeout" is set,
	  * it is propogated to the Expect variable
	  */
	void opIndexAssign(string value, string name){
		if(name == "timeout" && this.expect !is null)
			expect.timeout = value.to!long;
		if(name == "?")
			throw new ExpectScriptException("Trying to set a variable named '?'");
		this.variables[name] = value;
	}
	string opIndex(string name){
		return this.variables[name];
	}

	@disable this();
	this(ParseTree t){
		this.theScript = t;
	}
	/**
	  * Runs this script.
	  * Returns true if the script succeeds
	  */
	bool run(){
		try{
			this.handleScript(theScript);
		} catch(ExpectException e){
			return false;
		} catch(ExpectScriptParseException e){
			stderr.writefln("An error occured.\n%s", e.msg);
			return false;
		}
		return true;
	}

	/**
	  * Handles the script, delegating the work down to it's helper functions
	  */
	void handleScript(ParseTree script){
		assert(script.name == "ScriptGrammar.Script");
		auto blocks = script.children;
		blocks.each!(block => this.handleBlock(block, expect));
	}

	/*
	 * Handles a Block, parsing it's Attributes if required, and delegating its children to
	 * handleEnclosedBlock or handleStatement, depending on it's type.
	 */
	void handleBlock(ParseTree block, ref Expect e){
		// checks whether we should run this block
		// A block should be run if it has no ScriptGrammar.OSAttr attribute, or if it has no
		// ScriptGrammar.OSAttr not pointing at this os
		auto doRun = block.getAttributes("ScriptGrammar.OSAttr")
			.map!(attr => attr.children[0])
			.filter!(osAttr => osAttr.matches[0] != os)
			.empty;
		if(doRun == false){
			return;
		}

		block.children
			.filter!(child => child.name != "ScriptGrammar.Attribute") // remove attribute blocks, as we dont need em anymore
			.filter!(child => child.children.length > 0) // remove empty blocks
			.each!((node){
				switch(node.name){
					case "ScriptGrammar.EnclosedBlock":
						handleEnclosedBlock(node, e);
						break;
					case "ScriptGrammar.OpenBlock":
						handleStatement(node.children[0], e);
						break;
					default: throw new ExpectScriptParseException(format("Error parsing ParseTree - data %s", node));
				}
			});
	}

	void handleEnclosedBlock(ParseTree block, ref Expect e){
		block.children
			.each!((node){
				switch(node.name){
					case "ScriptGrammar.Block":
						handleBlock(node, e);
						break;
					case "ScriptGrammar.Statement":
						handleStatement(node, e);
						break;
					default: throw new ExpectScriptParseException(format("Error parsing ParseTree - data %s", node));
				}
			});
	}

	void handleStatement(ParseTree statement, ref Expect e){
		statement.children
			.each!((child){
				switch(child.name){
					case "ScriptGrammar.Spawn":
						handleSpawn(child, e);
						break;
					case "ScriptGrammar.Expect":
						handleExpect(child, e);
						break;
					case "ScriptGrammar.Set":
						handleSet(child);
						break;
					case "ScriptGrammar.Send":
						handleSend(child, e);
						break;
					default: throw new ExpectScriptParseException(format("Error parsing ParseTree - data %s", child));
				}
			});
	}

	void handleSend(ParseTree send, ref Expect e){
		if(send.children.length == 0)
			throw new ExpectScriptParseException("Error parsing set command");

		string sendHelper(ParseTree toSend){
			string str;
			foreach(child; toSend.children){
				switch(child.name){
					case "ScriptGrammar.String":
						str ~= child.matches[0];
						break;
					case "ScriptGrammar.Variable":
						str ~= this[child.matches[0]];
						break;
					case "ScriptGrammar.ToSend":
						str ~= sendHelper(child);
						break;
					default: throw new ExpectScriptParseException(format("Error parsing ParseTree - data %s", child));
				}
			}
			return str;
		}
		e.sendLine(sendHelper(send.children[0]));
	}
	void handleSet(ParseTree set){
		if(set.children.length != 2)
			throw new ExpectScriptParseException("Error parsing set command");
		string setHelper(ParseTree toSet){
			string str;
			foreach(child; toSet.children){
				switch(child.name){
					case "ScriptGrammar.String":
						str ~= child.matches[0];
						break;
					case "ScriptGrammar.Variable":
						str ~= this[child.matches[0]];
						break;
					case "ScriptGrammar.SetVal":
						str ~= setHelper(child);
						break;
					default: throw new ExpectScriptParseException(format("Error parsing ParseTree - data %s", child));
				}
			}
			return str;
		}
		string name, value;
		foreach(child; set.children){
			if(child.name == "ScriptGrammar.SetVar")
				name = child.matches[0];
			else if(child.name == "ScriptGrammar.SetVal")
				value = setHelper(child);
		}
		this[name] = value;
	}

	void handleExpect(ParseTree expect, ref Expect e){
		if(expect.children.length ==0 )
			throw new ExpectScriptParseException("Error parsing expect command");
		if(e is null)
			throw new ExpectScriptParseException("Cannot call expect before spawning");
		string expectHelper(ParseTree toExpect){
			string str;
			foreach(child; toExpect.children){
				switch(child.name){
					case "ScriptGrammar.String":
						str ~= child.matches[0];
						break;
					case "ScriptGrammar.Variable":
						str ~= this[child.matches[0]];
						break;
					case "ScriptGrammar.ToExpect":
						str ~= expectHelper(child);
						break;
					default: throw new ExpectScriptParseException(format("Error parsing ParseTree - data %s", child));
				}
			}
			return str;
		}
		e.expect(expectHelper(expect.children[0]));
	}

	void handleSpawn(ParseTree spawn, ref Expect e){
		if(spawn.children.length == 0)
			throw new ExpectScriptParseException("Error parsing spawn command");
		string spawnHelper(ParseTree toSpawn){
			string str;
			foreach(child; toSpawn.children){
				switch(child.name){
					case "ScriptGrammar.String":
						str ~= child.matches[0];
						break;
					case "ScriptGrammar.Variable":
						str ~= this[child.matches[0]];
						break;
					case "ScriptGrammar.ToSpawn":
						str ~= spawnHelper(child);
						break;
					default: throw new ExpectScriptParseException(format("Error parsing ParseTree - data %s", child));
				}
			}
			return str;
		}
		e = new Expect(spawnHelper(spawn.children[0]), this.sink);
		if(this.keys.canFind("timeout"))
			e.timeout = this["timeout"].to!long;
	}
}
auto getAttributes(ParseTree tree){ //checks if this tree has attributes
	return tree.children
		.filter!(child => child.name == "ScriptGrammar.Attribute");
}
auto getAttributes(ParseTree tree, string attrName){ //checks if this tree has attributes
	return tree.getAttributes
		.filter!(attr => attr.children.length > 0)
		.filter!(attr => attr.children[0].name == attrName);
}

mixin(grammar(scriptGrammar));

/// Grammar to be parsed by pegged
/// Potentially full of bugs
enum scriptGrammar = `
ScriptGrammar:
	# This is a simple testing bed for grammars
	Script		<- (EmptyLine / Block)+ :eoi
	Block		<- Attribute? (:' ' Attribute)* (EnclosedBlock / OpenBlock) :Whitespace*

	Attribute  <- ( OSAttr )
	OSAttr       <- ('win' / 'linux')

	EnclosedBlock <- :Whitespace* '{'
					 ( :Whitespace* (Statement / Block) :Whitespace* )*
					 :Whitespace* '}' :Whitespace*
	OpenBlock	<- (:Whitespace* Statement :Whitespace*)

	Statement	<- :Whitespace* (Comment / Spawn / Send / Expect / Set) :Spacing* :Whitespace*

	Comment		<: :Spacing* '#' (!eoi !endOfLine .)*

	Spawn		<- :"spawn" :Spacing* ToSpawn
	ToSpawn	<- (~Variable / ~String) :Spacing ('~' :Spacing ToSpawn)*

	Send		<- :"send" :Spacing* ToSend
	ToSend	<- (~Variable / ~String) :Spacing ('~' :Spacing ToSend)*

	Expect		<- :"expect" :Spacing* ToExpect
	ToExpect	<- (~Variable / ~String) :Spacing ('~' :Spacing ToExpect)*

	Set			<- :'set' :Spacing* SetVar :Spacing :'=' Spacing SetVal
	SetVar		<- ~VarName
	SetVal		<- (~Variable / ~String) :Spacing ('~' :Spacing SetVal)*

	Keyword		<~ ('#' / 'set' / 'expect' / 'spawn' / 'send')
	KeywordData <~ (!eoi !endOfLine .)+

	Variable    	<- :"$(" VarName :")"
	VarName     	<- (!eoi !endOfLine !')' !'(' !'$' !'=' !'~' .)+

	Text			<- (!eoi !endOfLine !'~' .)+
	DoubleQuoteText <- :doublequote
					   (!eoi !endOfLine !doublequote .)+
					   :doublequote
	SingleQuoteText <- :"'"
					   (!eoi !endOfLine !"'" .)+
					   :"'"
	String		<- (
					~DoubleQuoteText /
					~SingleQuoteText /
					~Text
				   )
	Whitespace  <- (Spacing / EmptyLine)
	EmptyLine   <- ('\n\r' / '\n')+
`;

/+ --------------- Utils --------------- +/

// Strits a string up to the first instance of c
string stripToFirst(string str, char c){
	return str[0..str.indexOf(c)];
}
/**
  * Exceptions thrown during expecting data.
  */
class ExpectScriptParseException : Exception {
	this(string message, string file = __FILE__, size_t line = __LINE__, Throwable next = null){
		super(message, file, line, next);
	}
}
class ExpectScriptException : Exception {
	this(string message, string file = __FILE__, size_t line = __LINE__, Throwable next = null){
		super(message, file, line, next);
	}
}

}
else{}

