defmodule Thrift.Generator.Binary.Framed.Server do
  @moduledoc false
  alias Thrift.AST.Function

  alias Thrift.Generator.{
    Service,
    Utils
  }

  alias Thrift.Parser.FileGroup

  def generate(service_module, service, file_group) do
    functions =
      service.functions
      |> Map.values()
      |> Enum.map(&generate_handler_function(file_group, service_module, &1))

    quote do
      defmodule Binary.Framed.Server do
        @moduledoc false
        require Logger

        alias Thrift.Binary.Framed.Server, as: ServerImpl
        defdelegate stop(name), to: ServerImpl

        def start_link(handler_module, port, opts \\ []) do
          ServerImpl.start_link(__MODULE__, port, handler_module, opts)
        end

        unquote_splicing(functions)

        def handle_thrift(method, _binary_data, _handler_module) do
          error =
            Thrift.TApplicationException.exception(
              type: :unknown_method,
              message: "Unknown method: #{method}"
            )

          {:server_error, error}
        end
      end
    end
  end

  def generate_handler_function(file_group, service_module, %Function{params: []} = function) do
    fn_name = Atom.to_string(function.name)
    handler_fn_name = Utils.underscore(function.name)
    response_module = Module.concat(service_module, Service.module_name(function, :response))
    handler_args = []
    body = build_responder(function.return_type, handler_fn_name, handler_args, response_module)
    handler = wrap_with_try_catch(body, function, file_group, response_module)

    quote do
      def handle_thrift(unquote(fn_name), _binary_data, handler_module) do
        unquote(handler)
      end
    end
  end

  def generate_handler_function(file_group, service_module, function) do
    fn_name = Atom.to_string(function.name)
    args_module = Module.concat(service_module, Service.module_name(function, :args))
    response_module = Module.concat(service_module, Service.module_name(function, :response))

    struct_matches =
      Enum.map(function.params, fn param ->
        {param.name, Macro.var(param.name, nil)}
      end)

    quote do
      def handle_thrift(unquote(fn_name), binary_data, handler_module) do
        case unquote(Module.concat(args_module, BinaryProtocol)).deserialize(binary_data) do
          {%unquote(args_module){unquote_splicing(struct_matches)}, ""} ->
            unquote(build_handler_call(file_group, function, response_module))

          {_, extra} ->
            raise Thrift.TApplicationException,
              type: :protocol_error,
              message: "Could not decode #{inspect(extra)}"
        end
      end
    end
  end

  defp build_handler_call(file_group, function, response_module) do
    handler_fn_name = Utils.underscore(function.name)
    handler_args = Enum.map(function.params, &Macro.var(&1.name, nil))
    body = build_responder(function.return_type, handler_fn_name, handler_args, response_module)
    wrap_with_try_catch(body, function, file_group, response_module)
  end

  defp wrap_with_try_catch(body, function, file_group, response_module) do
    # Quoted clauses for exception types defined by the schema.
    exception_clauses =
      Enum.flat_map(function.exceptions, fn
        exc ->
          resolved = FileGroup.resolve(file_group, exc)
          dest_module = FileGroup.dest_module(file_group, resolved.type)
          error_var = Macro.var(exc.name, nil)
          field_setter = quote do: {unquote(exc.name), unquote(error_var)}

          quote do
            :error, %unquote(dest_module){} = unquote(error_var) ->
              response = %unquote(response_module){unquote(field_setter)}

              {:reply,
               unquote(Module.concat(response_module, BinaryProtocol)).serialize(response)}
          end
      end)

    # Quoted clauses for our standard catch clauses (common to all functions).
    catch_clauses =
      quote do
        kind, reason ->
          formatted_exception = Exception.format(kind, reason, System.stacktrace())
          Logger.error("Exception not defined in thrift spec was thrown: #{formatted_exception}")

          error =
            Thrift.TApplicationException.exception(
              type: :internal_error,
              message: "Server error: #{formatted_exception}"
            )

          {:server_error, error}
      end

    quote do
      try do
        unquote(body)
      catch
        unquote(Enum.concat(exception_clauses, catch_clauses))
      end
    end
  end

  defp build_responder(:void, handler_fn_name, handler_args, _response_module) do
    quote do
      _result = handler_module.unquote(handler_fn_name)(unquote_splicing(handler_args))
      :noreply
    end
  end

  defp build_responder(_, handler_fn_name, handler_args, response_module) do
    quote do
      result = handler_module.unquote(handler_fn_name)(unquote_splicing(handler_args))
      response = %unquote(response_module){success: result}
      {:reply, unquote(Module.concat(response_module, BinaryProtocol)).serialize(response)}
    end
  end
end
