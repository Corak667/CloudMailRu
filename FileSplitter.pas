unit FileSplitter;

interface

type

	SplittedFile = record
		filename: WideString;
		size: int64;
		crc32: WideString; // String representation
		parts: integer;
	end;

	TFileSplitter = class
	public
		constructor �reate(filename: WideString; SplitSize: int64 = $80000000);
		destructor Destroy; override;

	end;

implementation

{ TFileSplitter }

destructor TFileSplitter.Destroy;
begin

	inherited;
end;

constructor TFileSplitter.�reate(filename: WideString; SplitSize: int64);
begin

end;

end.
