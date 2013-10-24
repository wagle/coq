(************************************************************************)
(*  v      *   The Coq Proof Assistant  /  The Coq Development Team     *)
(* <O___,, *   INRIA - CNRS - LIX - LRI - PPS - Copyright 1999-2012     *)
(*   \VV/  **************************************************************)
(*    //   *      This file is distributed under the terms of the       *)
(*         *       GNU Lesser General Public License Version 2.1        *)
(************************************************************************)

open Pp
open Errors
open Util

open Names
open Libnames
open Nameops
open Libobject
open Lib

(************************************************************************)
(*s Modules on disk contain the following informations (after the magic
    number, and before the digest). *)

type compilation_unit_name = DirPath.t

type library_disk = {
  md_name : compilation_unit_name;
  md_compiled : Safe_typing.compiled_library;
  md_objects : Declaremods.library_objects;
  md_deps : (compilation_unit_name * Digest.t) array;
  md_imports : compilation_unit_name array }

(*s Modules loaded in memory contain the following informations. They are
    kept in the global table [libraries_table]. *)

type library_t = {
  library_name : compilation_unit_name;
  library_compiled : Safe_typing.compiled_library;
  library_objects : Declaremods.library_objects;
  library_deps : (compilation_unit_name * Digest.t) array;
  library_imports : compilation_unit_name array;
  library_digest : Digest.t }

module LibraryOrdered = DirPath
module LibraryMap = Map.Make(LibraryOrdered)
module LibraryFilenameMap = Map.Make(LibraryOrdered)

(* This is a map from names to loaded libraries *)
let libraries_table = Summary.ref LibraryMap.empty ~name:"LIBRARY"

(* This is the map of loaded libraries filename *)
(* (not synchronized so as not to be caught in the states on disk) *)
let libraries_filename_table = ref LibraryFilenameMap.empty

(* These are the _ordered_ sets of loaded, imported and exported libraries *)
let libraries_loaded_list = Summary.ref [] ~name:"LIBRARY-LOAD"
let libraries_imports_list = Summary.ref [] ~name:"LIBRARY-IMPORT"
let libraries_exports_list = Summary.ref [] ~name:"LIBRARY-EXPORT"

(* various requests to the tables *)

let find_library dir =
  LibraryMap.find dir !libraries_table

let try_find_library dir =
  try find_library dir
  with Not_found ->
    error ("Unknown library " ^ (DirPath.to_string dir))

let register_library_filename dir f =
  (* Not synchronized: overwrite the previous binding if one existed *)
  (* from a previous play of the session *)
  libraries_filename_table :=
    LibraryFilenameMap.add dir f !libraries_filename_table

let library_full_filename dir =
  try LibraryFilenameMap.find dir !libraries_filename_table
  with Not_found -> "<unavailable filename>"

let overwrite_library_filenames f =
  let f =
    if Filename.is_relative f then Filename.concat (Sys.getcwd ()) f else f in
  LibraryMap.iter (fun dir _ -> register_library_filename dir f)
    !libraries_table

let library_is_loaded dir =
  try let _ = find_library dir in true
  with Not_found -> false

let library_is_opened dir =
  List.exists (fun m -> DirPath.equal m.library_name dir) !libraries_imports_list

let loaded_libraries () =
  List.map (fun m -> m.library_name) !libraries_loaded_list

let opened_libraries () =
  List.map (fun m -> m.library_name) !libraries_imports_list

  (* If a library is loaded several time, then the first occurrence must
     be performed first, thus the libraries_loaded_list ... *)

let register_loaded_library m =
  let link m =
    let dirname = Filename.dirname (library_full_filename m.library_name) in
    let prefix = Nativecode.mod_uid_of_dirpath m.library_name ^ "." in
    let f = prefix ^ "cmo" in
    let f = Dynlink.adapt_filename f in
    if not !Flags.no_native_compiler then
      Nativelib.call_linker ~fatal:false prefix (Filename.concat dirname f) None
  in
  let rec aux = function
    | [] -> link m; [m]
    | m'::_ as l when DirPath.equal m'.library_name m.library_name -> l
    | m'::l' -> m' :: aux l' in
  libraries_loaded_list := aux !libraries_loaded_list;
  libraries_table := LibraryMap.add m.library_name m !libraries_table

  (* ... while if a library is imported/exported several time, then
     only the last occurrence is really needed - though the imported
     list may differ from the exported list (consider the sequence
     Export A; Export B; Import A which results in A;B for exports but
     in B;A for imports) *)

let rec remember_last_of_each l m =
  match l with
  | [] -> [m]
  | m'::l' when DirPath.equal m'.library_name m.library_name -> remember_last_of_each l' m
  | m'::l' -> m' :: remember_last_of_each l' m

let register_open_library export m =
  libraries_imports_list := remember_last_of_each !libraries_imports_list m;
  if export then
    libraries_exports_list := remember_last_of_each !libraries_exports_list m

(************************************************************************)
(*s Opening libraries *)

(* [open_library export explicit m] opens library [m] if not already
   opened _or_ if explicitly asked to be (re)opened *)

let eq_lib_name m1 m2 = DirPath.equal m1.library_name m2.library_name

let open_library export explicit_libs m =
  if
    (* Only libraries indirectly to open are not reopen *)
    (* Libraries explicitly mentionned by the user are always reopen *)
    List.exists (eq_lib_name m) explicit_libs
    || not (library_is_opened m.library_name)
  then begin
    register_open_library export m;
    Declaremods.really_import_module (MPfile m.library_name)
  end
  else
    if export then
      libraries_exports_list := remember_last_of_each !libraries_exports_list m

(* open_libraries recursively open a list of libraries but opens only once
   a library that is re-exported many times *)

let open_libraries export modl =
  let to_open_list =
    List.fold_left
      (fun l m ->
         let subimport =
           Array.fold_left
             (fun l m -> remember_last_of_each l (try_find_library m))
             l m.library_imports
         in remember_last_of_each subimport m)
      [] modl in
  List.iter (open_library export modl) to_open_list


(**********************************************************************)
(* import and export  -  synchronous operations*)

let open_import i (_,(dir,export)) =
  if Int.equal i 1 then
    (* even if the library is already imported, we re-import it *)
    (* if not (library_is_opened dir) then *)
      open_libraries export [try_find_library dir]

let cache_import obj =
  open_import 1 obj

let subst_import (_,o) = o

let classify_import (_,export as obj) =
  if export then Substitute obj else Dispose

let in_import : DirPath.t * bool -> obj =
  declare_object {(default_object "IMPORT LIBRARY") with
       cache_function = cache_import;
       open_function = open_import;
       subst_function = subst_import;
       classify_function = classify_import }


(************************************************************************)
(*s Low-level interning/externing of libraries to files *)

(*s Loading from disk to cache (preparation phase) *)

let (raw_extern_library, raw_intern_library) =
  System.raw_extern_intern Coq_config.vo_magic_number

(************************************************************************)
(*s Locate absolute or partially qualified library names in the path *)

exception LibUnmappedDir
exception LibNotFound
type library_location = LibLoaded | LibInPath

let locate_absolute_library dir =
  (* Search in loadpath *)
  let pref, base = split_dirpath dir in
  let loadpath = Loadpath.expand_root_path pref in
  let () = match loadpath with [] -> raise LibUnmappedDir | _ -> () in
  try
    let name = (Id.to_string base)^".vo" in
    let _, file = System.where_in_path ~warn:false loadpath name in
    (dir, file)
  with Not_found ->
  (* Last chance, removed from the file system but still in memory *)
  if library_is_loaded dir then
    (dir, library_full_filename dir)
  else
    raise LibNotFound

let locate_qualified_library warn qid =
  try
    (* Search library in loadpath *)
    let dir, base = repr_qualid qid in
    let loadpath = Loadpath.expand_path dir in
    let () = match loadpath with [] -> raise LibUnmappedDir | _ -> () in
    let name = Id.to_string base ^ ".vo" in
    let lpath, file = System.where_in_path ~warn (List.map fst loadpath) name
    in
    let dir =
      add_dirpath_suffix (List.assoc_f String.equal lpath loadpath) base
    in
    (* Look if loaded *)
    if library_is_loaded dir then (LibLoaded, dir, library_full_filename dir)
    (* Otherwise, look for it in the file system *)
    else (LibInPath, dir, file)
  with Not_found -> raise LibNotFound

let error_unmapped_dir qid =
  let prefix, _ = repr_qualid qid in
  errorlabstrm "load_absolute_library_from"
    (str "Cannot load " ++ pr_qualid qid ++ str ":" ++ spc () ++
     str "no physical path bound to" ++ spc () ++ pr_dirpath prefix ++ fnl ())

let error_lib_not_found qid =
  errorlabstrm "load_absolute_library_from"
    (str"Cannot find library " ++ pr_qualid qid ++ str" in loadpath")

let try_locate_absolute_library dir =
  try
    locate_absolute_library dir
  with
    | LibUnmappedDir -> error_unmapped_dir (qualid_of_dirpath dir)
    | LibNotFound -> error_lib_not_found (qualid_of_dirpath dir)

let try_locate_qualified_library (loc,qid) =
  try
    let (_,dir,f) = locate_qualified_library (Flags.is_verbose()) qid in
    dir,f
  with
    | LibUnmappedDir -> error_unmapped_dir qid
    | LibNotFound -> error_lib_not_found qid

(************************************************************************)
(** {6 Tables of opaque proof terms} *)

(** We now store opaque proof terms apart from the rest of the environment.
    See the [Indirect] contructor in [Lazyconstr.lazy_constr]. This way,
    we can quickly load a first half of a .vo file without these opaque
    terms, and access them only when a specific command (e.g. Print or
    Print Assumptions) needs it. *)

exception Faulty

(** Fetching a table of opaque terms at position [pos] in file [f],
    expecting to find first a copy of [digest]. *)

let fetch_opaque_table (f,pos,digest) =
  if !Flags.load_proofs == Flags.Dont then
    error "Not accessing an opaque term due to option -dont-load-proofs.";
  try
    Pp.msg_info (Pp.str "Fetching opaque terms in " ++ str f);
    let ch = System.with_magic_number_check raw_intern_library f in
    let () = seek_in ch pos in
    if not (String.equal (System.digest_in f ch) digest) then raise Faulty;
    let table = (System.marshal_in f ch : Term.constr array) in
    (* Check of the final digest (the one also covering the opaques) *)
    let pos' = pos_in ch in
    let digest' = System.digest_in f ch in
    let () = close_in ch in
    let ch' = open_in f in
    if not (String.equal (Digest.channel ch' pos') digest') then raise Faulty;
    let () = close_in ch' in
    table
  with e when Errors.noncritical e ->
    error
      ("The file "^f^" is inaccessible or corrupted,\n"
       ^ "cannot load some opaque constant bodies in it.\n")

(** Delayed / available tables of opaque terms *)

type opaque_table_status =
  | ToFetch of string * int * Digest.t
  | Fetched of Term.constr array

let opaque_tables = ref (LibraryMap.empty : opaque_table_status LibraryMap.t)

let add_opaque_table dp st =
  opaque_tables := LibraryMap.add dp st !opaque_tables

let access_opaque_table dp i =
  let t = match LibraryMap.find dp !opaque_tables with
    | Fetched t -> t
    | ToFetch (f,pos,digest) ->
      let t = fetch_opaque_table (f,pos,digest) in
      add_opaque_table dp (Fetched t);
      t
  in
  assert (i < Array.length t); t.(i)

(** Table of opaque terms from the library currently being compiled *)

module OpaqueTables = struct

 let a_constr = Term.mkRel 1

 let local_table = ref (Array.make 100 a_constr)
 let local_index = ref 0

 let get dp i =
   if DirPath.equal dp (Lib.library_dp ())
   then (!local_table).(i)
   else access_opaque_table dp i

 let store c =
  let n = !local_index in
  incr local_index;
  if Int.equal n (Array.length !local_table) then begin
    let t = Array.make (2*n) a_constr in
    Array.blit !local_table 0 t 0 n;
    local_table := t
  end;
  (!local_table).(n) <- c;
  Some (Lib.library_dp (), n)

 let dump () = Array.sub !local_table 0 !local_index

end

let _ = Lazyconstr.set_indirect_opaque_accessor OpaqueTables.get

(************************************************************************)
(* Internalise libraries *)

let mk_library md digest =
  {
    library_name     = md.md_name;
    library_compiled = md.md_compiled;
    library_objects  = md.md_objects;
    library_deps     = md.md_deps;
    library_imports  = md.md_imports;
    library_digest    = digest
  }

let intern_from_file f =
  let ch = System.with_magic_number_check raw_intern_library f in
  let lmd = (System.marshal_in f ch : library_disk) in
  let pos = pos_in ch in
  let digest = System.digest_in f ch in
  register_library_filename lmd.md_name f;
  add_opaque_table lmd.md_name (ToFetch (f,pos,digest));
  let library = mk_library lmd digest in
  close_in ch;
  library

let rec intern_library needed (dir, f) =
  (* Look if in the current logical environment *)
  try find_library dir, needed
  with Not_found ->
  (* Look if already listed and consequently its dependencies too *)
  try List.assoc_f DirPath.equal dir needed, needed
  with Not_found ->
  (* [dir] is an absolute name which matches [f] which must be in loadpath *)
  let m = intern_from_file f in
  if not (DirPath.equal dir m.library_name) then
    errorlabstrm "load_physical_library"
      (str ("The file " ^ f ^ " contains library") ++ spc () ++
       pr_dirpath m.library_name ++ spc () ++ str "and not library" ++
       spc() ++ pr_dirpath dir);
  m, intern_library_deps needed dir m

and intern_library_deps needed dir m =
  (dir,m)::Array.fold_left (intern_mandatory_library dir) needed m.library_deps

and intern_mandatory_library caller needed (dir,d) =
  let m,needed = intern_library needed (try_locate_absolute_library dir) in
  if not (String.equal d m.library_digest) then
    errorlabstrm "" (strbrk ("Compiled library "^(DirPath.to_string caller)^
	   ".vo makes inconsistent assumptions over library "
	   ^(DirPath.to_string dir)));
  needed

let rec_intern_library needed mref =
  let _,needed = intern_library needed mref in needed

let check_library_short_name f dir = function
  | Some id when not (Id.equal id (snd (split_dirpath dir))) ->
      errorlabstrm "check_library_short_name"
      (str ("The file " ^ f ^ " contains library") ++ spc () ++
      pr_dirpath dir ++ spc () ++ str "and not library" ++ spc () ++
      pr_id id)
  | _ -> ()

let rec_intern_by_filename_only id f =
  let m = try intern_from_file f with Sys_error s -> error s in
  (* Only the base name is expected to match *)
  check_library_short_name f m.library_name id;
  if !Flags.print_mod_uid then
    print_endline (Nativecode.mod_uid_of_dirpath m.library_name);
  (* We check no other file containing same library is loaded *)
  if library_is_loaded m.library_name then
    begin
      msg_warning
	(pr_dirpath m.library_name ++ str " is already loaded from file " ++
	str (library_full_filename m.library_name));
      m.library_name, []
    end
 else
    let needed = intern_library_deps [] m.library_name m in
    m.library_name, needed

let rec_intern_library_from_file idopt f =
  (* A name is specified, we have to check it contains library id *)
  let paths = Loadpath.get_paths () in
  let _, f =
    System.find_file_in_path ~warn:(Flags.is_verbose()) paths (f^".vo") in
  rec_intern_by_filename_only idopt f

(**********************************************************************)
(*s [require_library] loads and possibly opens a library. This is a
    synchronized operation. It is performed as follows:

  preparation phase: (functions require_library* ) the library and its
    dependencies are read from to disk (using intern_* )
    [they are read from disk to ensure that at section/module
     discharging time, the physical library referred to outside the
     section/module is the one that was used at type-checking time in
     the section/module]

  execution phase: (through add_leaf and cache_require)
    the library is loaded in the environment and Nametab, the objects are
    registered etc, using functions from Declaremods (via load_library,
    which recursively loads its dependencies)
*)

let register_library m =
  Declaremods.register_library
    m.library_name
    m.library_compiled
    m.library_objects
    m.library_digest;
  register_loaded_library m

(* Follow the semantics of Anticipate object:
   - called at module or module type closing when a Require occurs in
     the module or module type
   - not called from a library (i.e. a module identified with a file) *)
let load_require _ (_,(needed,modl,_)) =
  List.iter register_library needed

let open_require i (_,(_,modl,export)) =
  Option.iter (fun exp -> open_libraries exp (List.map find_library modl))
    export

  (* [needed] is the ordered list of libraries not already loaded *)
let cache_require o =
  load_require 1 o;
  open_require 1 o

let discharge_require (_,o) = Some o

(* open_function is never called from here because an Anticipate object *)

type require_obj = library_t list * DirPath.t list * bool option

let in_require : require_obj -> obj =
  declare_object {(default_object "REQUIRE") with
       cache_function = cache_require;
       load_function = load_require;
       open_function = (fun _ _ -> assert false);
       discharge_function = discharge_require;
       classify_function = (fun o -> Anticipate o) }

(* Require libraries, import them if [export <> None], mark them for export
   if [export = Some true] *)

let (f_xml_require, xml_require) = Hook.make ~default:ignore ()

let require_library_from_dirpath modrefl export =
  let needed = List.fold_left rec_intern_library [] modrefl in
  let needed = List.rev_map snd needed in
  let modrefl = List.map fst modrefl in
    if Lib.is_module_or_modtype () then
      begin
	add_anonymous_leaf (in_require (needed,modrefl,None));
	Option.iter (fun exp ->
	  List.iter (fun dir -> add_anonymous_leaf (in_import(dir,exp))) modrefl)
	  export
      end
    else
      add_anonymous_leaf (in_require (needed,modrefl,export));
    if !Flags.xml_export then List.iter (Hook.get f_xml_require) modrefl;
  add_frozen_state ()

let require_library qidl export =
  let modrefl = List.map try_locate_qualified_library qidl in
    require_library_from_dirpath modrefl export

let require_library_from_file idopt file export =
  let modref,needed = rec_intern_library_from_file idopt file in
  let needed = List.rev_map snd needed in
  if Lib.is_module_or_modtype () then begin
    add_anonymous_leaf (in_require (needed,[modref],None));
    Option.iter (fun exp -> add_anonymous_leaf (in_import (modref,exp)))
      export
  end
  else
    add_anonymous_leaf (in_require (needed,[modref],export));
  if !Flags.xml_export then Hook.get f_xml_require modref;
  add_frozen_state ()

(* the function called by Vernacentries.vernac_import *)

let import_module export (loc,qid) =
  try
    match Nametab.locate_module qid with
      | MPfile dir ->
	  if Lib.is_module_or_modtype () || not export then
	    add_anonymous_leaf (in_import (dir, export))
	  else
	    add_anonymous_leaf (in_import (dir, export))
      | mp ->
	  Declaremods.import_module export mp
  with
      Not_found ->
	user_err_loc
          (loc,"import_library",
	  str ((string_of_qualid qid)^" is not a module"))

(************************************************************************)
(*s Initializing the compilation of a library. *)

let check_coq_overwriting p id =
  let l = DirPath.repr p in
  let is_empty = match l with [] -> true | _ -> false in
  if not !Flags.boot && not is_empty && String.equal (Id.to_string (List.last l)) "Coq" then
    errorlabstrm ""
      (strbrk ("Cannot build module "^DirPath.to_string p^"."^Id.to_string id^
      ": it starts with prefix \"Coq\" which is reserved for the Coq library."))

let start_library f =
  let paths = Loadpath.get_paths () in
  let _, longf =
    System.find_file_in_path ~warn:(Flags.is_verbose()) paths (f^".v") in
  let ldir0 =
    try
      let lp = Loadpath.find_load_path (Filename.dirname longf) in
      Loadpath.logical lp
    with Not_found -> Nameops.default_root_prefix
  in
  let id = Id.of_string (Filename.basename f) in
  check_coq_overwriting ldir0 id;
  let ldir = add_dirpath_suffix ldir0 id in
  Lazyconstr.set_indirect_opaque_creator OpaqueTables.store;
  Declaremods.start_library ldir;
  ldir,longf

(************************************************************************)
(*s [save_library dir] ends library [dir] and save it to the disk. *)

let current_deps () =
  List.map (fun m -> (m.library_name, m.library_digest)) !libraries_loaded_list

let current_reexports () =
  List.map (fun m -> m.library_name) !libraries_exports_list

let error_recursively_dependent_library dir =
  errorlabstrm ""
    (strbrk "Unable to use logical name " ++ pr_dirpath dir ++
     strbrk " to save current library because" ++
     strbrk " it already depends on a library of this name.")

(* We now use two different digests in a .vo file. The first one
   only covers half of the file, without the opaque table. It is
   used for identifying this version of this library : this digest
   is the one leading to "inconsistent assumptions" messages.
   The other digest comes at the very end, and covers everything
   before it. This one is used for integrity check of the whole
   file when loading the opaque table. *)

(* Security weakness: file might have been changed on disk between
   writing the content and computing the checksum... *)

let save_library_to dir f =
  Lazyconstr.reset_indirect_opaque_creator ();
  let cenv, seg, ast = Declaremods.end_library dir in
  let table = OpaqueTables.dump () in
  let md = {
    md_name = dir;
    md_compiled = cenv;
    md_objects = seg;
    md_deps = Array.of_list (current_deps ());
    md_imports = Array.of_list (current_reexports ()) } in
  if Array.exists (fun (d,_) -> DirPath.equal d dir) md.md_deps then
    error_recursively_dependent_library dir;
  (* Open the vo file and write the magic number *)
  let (f',ch) = raw_extern_library f in
  try
    (* Writing vo payload *)
    System.marshal_out ch md; (* env + objs *)
    System.digest_out ch (Digest.file f'); (* 1st checksum *)
    System.marshal_out ch table; (* opaques *)
    System.digest_out ch (Digest.file f'); (* 2nd checksum *)
    close_out ch;
    (* Writing native code files *)
    if not !Flags.no_native_compiler then begin
    let lp = Loadpath.get_load_paths () in
    let map_path p = CUnix.string_of_physical_path (Loadpath.physical p) in
    let lp = List.map map_path lp in
    let fn = Filename.dirname f'^"/"^Nativecode.mod_uid_of_dirpath dir in
    match Nativelibrary.compile_library dir ast lp fn with
      | 0 -> ()
      | _ -> anomaly (Pp.str "Library compilation failure")
    end
  with reraise ->
    let reraise = Errors.push reraise in
    let () = msg_warning (str ("Removed file "^f')) in
    let () = close_out ch in
    let () = Sys.remove f' in
    raise reraise

(************************************************************************)
(*s Display the memory use of a library. *)

open Printf

let mem s =
  let m = try_find_library s in
  h 0 (str (sprintf "%dk (cenv = %dk / seg = %dk)"
		 (CObj.size_kb m) (CObj.size_kb m.library_compiled)
		 (CObj.size_kb m.library_objects)))

let get_load_paths_str () =
  let lp = Loadpath.get_load_paths () in
  let map_path p = CUnix.string_of_physical_path (Loadpath.physical p) in
  List.map map_path lp

let _ = Nativelib.get_load_paths := get_load_paths_str
