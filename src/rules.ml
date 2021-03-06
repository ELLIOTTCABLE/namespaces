(* This file is part of Namespaces, distributed under the terms of the 2-clause
   BSD license. See https://github.com/aantron/namespaces. *)

open Ocamlbuild_plugin

let sprintf = Printf.sprintf

let fail =
  let exceptions : (string, exn) Hashtbl.t = Hashtbl.create 512 in
  let space = Str.regexp " " in
  fun file message ->
    let transformed =
      sprintf "___%s___%s___" file (Str.global_replace space "_" message) in
    fun build ->
      try Hashtbl.find exceptions transformed |> raise
      with Not_found ->
        match build [[transformed]] with
        | [Outcome.Bad e] -> Hashtbl.add exceptions transformed e; raise e
        | _               ->
          failwith "Couldn't capture solver failure exception"

let make_directory for_file =
  Command.execute (Cmd (S [A "mkdir"; A "-p"; A (Filename.dirname for_file)]))

let get_namespace env build =
  match Modules.namespace_by_final_directory (env "%") with
  | Some n -> n
  | None   -> fail (env "%") "not a namespace" build

let digest_file_rule () =
  let name = sprintf "namespace: directory -> %s" (Modules.digest_file "") in
  let prod = Modules.digest_file "%" in
  rule name ~stamp:prod
    begin
      fun env build ->
        get_namespace env build
        |> Modules.digest_dependencies
        |> List.map (fun f -> [f])
        |> build
        |> List.map Outcome.ignore_good |> ignore;
        Nop
    end

let alias_file_generation_rule () =
  let name =
    sprintf "namespace: directory -> %s" (Modules.alias_container_file "") in
  let prod = Modules.alias_container_file "%" in
  rule name ~prod
    begin
      fun env build ->
        let namespace = get_namespace env build in
        make_directory (env prod);
        Echo ([Modules.alias_file_contents namespace], env prod)
    end

let namespace_file_generation_rule () =
  let prod = "%.ml" in
  let dep = "%.digest" in
  rule "namespace: directory -> ml" ~dep ~prod
    begin
      fun env build ->
        let namespace = get_namespace env build in
        let digest = Pathname.read (env dep) in
        make_directory (env prod);
        Echo ([Modules.namespace_file_contents namespace digest], env prod)
    end

let long_name_rules () =
  let for_extension extension =
    let name =
      sprintf "namespace: %s -> %s (long name)" extension extension in
    let prod = "%." ^ extension in
    rule name ~prod
      begin
        fun env build ->
          let file =
            match Modules.file_by_renamed_path (env prod) with
            | Some f -> f
            | None   -> fail (env prod) "not a namespaced file" build in

          build [[Modules.original_path file]]
          |> List.map Outcome.ignore_good |> ignore;

          (* Transfer tags from the target to the link. *)
          Modules.original_path file
          |> tags_of_pathname
          |> Tags.elements
          |> tag_file (env prod);

          ln_s file.Modules.original_name (env prod)
      end in

  for_extension "ml";
  for_extension "mli"

let dependency_filter_rules () =
  let whitespace = Str.regexp "[ \n\t\r]+" in
  let for_extension extension =
    let name = sprintf "namespace dependencies %s" extension in
    let prod = sprintf "%%.%s.depends" extension in
    let dep = sprintf "%%.%s" extension in
    rule name ~prod ~dep ~insert:`top
      begin
        fun env build ->
          let file =
            match Modules.file_by_renamed_path (env dep) with
            | Some f -> f
            | None   -> fail (env prod) "not a namespaced file" build in

          let tags =
            (tags_of_pathname (env prod)) ++ "ocamldep" ++ "pp:dep" in

          let command =
            S [A "ocamlfind"; A "ocamldep"; T tags; A "-modules";
                                            A (env dep)] in

          let dependency_string =
            Command.string_of_command_spec command |> run_and_read in

          let colon_index = String.index dependency_string ':' in
          let remainder =
            String.length dependency_string - (colon_index + 1) in
          let dependencies =
            String.sub dependency_string (colon_index + 1) remainder
            |> Str.split whitespace
            |> List.filter (fun s -> String.length s > 0) in

          let resolved_dependencies =
            dependencies |> List.map (Modules.resolve file) in

          let text =
            ((env dep) ^ ":")::resolved_dependencies
            |> String.concat " "
            |> fun s -> s ^ "\n" in

          Echo ([text], env prod)
      end in

  for_extension "ml";
  for_extension "mli"

let dependencies_from_log =
  let newline = Str.regexp_string "\n" in
  let compiled =
    Str.regexp "ocamlfind ocaml\\(c\\|opt\\).* \\([^ ]+\\.ml\\)$" in

  fun () ->
    if not @@ Sys.file_exists "_log" then
      failwith "_log not present; are you running with -quiet?";

    "cat _log"
    |> run_and_read
    |> Str.split newline
    |> List.fold_left (fun acc line ->
      if not @@ Str.string_match compiled line 0 then acc
      else (Str.matched_group 2 line)::acc) []
    |> List.rev_map module_name_of_pathname

let library_rule () =
  let name = "namespace: * -> mllib" in
  let prod = Modules.library_list_file "%" in
  rule name ~prod
    begin
      fun env build ->
        let module_files =
          match Modules.library_contents_by_final_base_path (env "%") with
          | Some s -> s
          | None   -> fail (env prod) "not a namespace library" build in

        (* Build the library contents to get a topological sort according to the
           internal dependency relation. *)
        module_files
        |> List.map (fun file ->
          let file =
            if Filename.check_suffix file ".ml" then file
            else file ^ ".ml" in
          [file ^ ".depends"])
        |> build
        |> List.map Outcome.ignore_good
        |> ignore;

        let order_snapshot = dependencies_from_log () in

        let order_index module_name =
          let rec scan n = function
            | [] -> -1
            | name::rest ->
              if module_name = name then n else scan (n + 1) rest in
          scan 0 order_snapshot in

        let text =
          module_files
          |> List.map (fun file ->
            let name = module_name_of_pathname file in
            (name, order_index name))
          |> List.sort (fun (_, index) (_, index') -> compare index index')
          |> List.map fst
          |> String.concat "\n" in

        make_directory (env prod);
        Echo ([text], env prod)
    end

(* A side-effecting rule for each executable, that makes each executable depend
   on all the libraries in the same project. It is not possible to use
   [Options.targets] for this purpose, because that contains the literal names
   of each target, as given on the command line. If the user gives a target such
   as [main.byte], when the "real" target is [src/main.byte], Ocamlbuild will
   build [src/main.byte], [Options.targets] will contain [main.byte], and
   Ocamlbuild will ignore tags of [main.byte]. *)
let executable_rules () =
  let for_extension extension =
    let name = sprintf "executable dependencies %s" extension in
    let prod = sprintf "%%.%s" extension in
    rule name ~prod ~insert:`top
      begin
        fun env build ->
          Modules.tag_executable_with_libraries (env prod);
          fail (env prod) "__dummy_target__" build
      end in

  for_extension "byte";
  for_extension "native"



let add_all () =
  digest_file_rule ();
  alias_file_generation_rule ();
  namespace_file_generation_rule ();
  long_name_rules ();
  dependency_filter_rules ();
  library_rule ();
  executable_rules ()
