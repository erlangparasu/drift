import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:sqlparser/sqlparser.dart';
import 'package:sqlparser/utils/find_referenced_tables.dart';

import '../../backend.dart';
import '../../driver/error.dart';
import '../../driver/state.dart';
import '../../results/results.dart';
import '../resolver.dart';
import '../shared/dart_types.dart';
import 'sqlparser/drift_lints.dart';

abstract class DriftElementResolver<T extends DiscoveredElement>
    extends LocalElementResolver<T> {
  DriftElementResolver(
      super.file, super.discovered, super.resolver, super.state);

  void reportLints(AnalysisContext context) {
    context.errors.forEach(reportLint);

    // Also run drift-specific lints on the query
    final linter = DriftSqlLinter(context, this)..collectLints();
    linter.sqlParserErrors.forEach(reportLint);
  }

  Future<FoundDartClass?> findDartClass(String identifier) async {
    final dartImports = file.discovery!.importDependencies
        .where((importUri) => importUri.path.endsWith('.dart'));

    for (final import in dartImports) {
      LibraryElement library;
      try {
        library = await resolver.driver.backend.readDart(import);
      } on NotALibraryException {
        continue;
      }

      final foundElement = library.exportNamespace.get(identifier);
      if (foundElement is InterfaceElement) {
        return FoundDartClass(foundElement, null);
      } else if (foundElement is TypeAliasElement) {
        final innerType = foundElement.aliasedType;
        if (innerType is InterfaceType) {
          return FoundDartClass(innerType.element2, innerType.typeArguments);
        }
      }
    }

    return null;
  }

  SqlEngine newEngineWithTables(Iterable<DriftElement> references) {
    final driver = resolver.driver;
    final engine = driver.newSqlEngine();

    for (final reference in references) {
      if (reference is DriftTable) {
        engine.registerTable(driver.typeMapping.asSqlParserTable(reference));
      } else if (reference is DriftView) {
        engine.registerView(driver.typeMapping.asSqlParserView(reference));
      }
    }

    return engine;
  }

  Future<List<DriftElement>> resolveSqlReferences(AstNode stmt) async {
    final references =
        resolver.driver.newSqlEngine().findReferencedSchemaTables(stmt);
    final found = <DriftElement>[];

    for (final table in references) {
      final result = await resolver.resolveReference(discovered.ownId, table);

      if (result is ResolvedReferenceFound) {
        found.add(result.element);
      } else {
        final referenceNode = stmt.allDescendants
            .firstWhere((e) => e is TableReference && e.tableName == table);

        reportErrorForUnresolvedReference(result,
            (msg) => DriftAnalysisError.inDriftFile(referenceNode, msg));
      }
    }

    return found;
  }

  void reportLint(AnalysisError parserError) {
    reportError(
        DriftAnalysisError(parserError.span, parserError.message ?? ''));
  }
}