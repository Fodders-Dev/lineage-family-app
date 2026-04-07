import os, re

models_dir = 'lib/models'
for root, _, files in os.walk(models_dir):
    for file in files:
        if file.endswith('.dart'):
            filepath = os.path.join(root, file)
            with open(filepath, 'r', encoding='utf-8') as f:
                content = f.read()

            # Remove unused uuid import if Uuid() not actually used
            if "import 'package:uuid/uuid.dart';" in content and "Uuid()" not in content:
                content = content.replace("import 'package:uuid/uuid.dart';\n", "")

            # Remove unused date_parser import if parseDateTime not actually used
            if "import '../utils/date_parser.dart';" in content:
                if "parseDateTime" not in content:
                    content = content.replace("import '../utils/date_parser.dart';\n", "")

            with open(filepath, 'w', encoding='utf-8') as f:
                f.write(content)

print("Done cleaning unused imports in models.")
