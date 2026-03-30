import 'package:flutter/material.dart';

class CountryPicker extends StatefulWidget {
  final String? initialCountry;
  final Function(String country, String countryCode) onCountryChanged;

  const CountryPicker({
    Key? key,
    this.initialCountry,
    required this.onCountryChanged,
  }) : super(key: key);

  @override
  _CountryPickerState createState() => _CountryPickerState();
}

class _CountryPickerState extends State<CountryPicker> {
  String? _selectedCountry;

  final Map<String, String> _countryCodes = {
    'Россия': '+7',
    'США': '+1',
    'Великобритания': '+44',
    'Германия': '+49',
    'Франция': '+33',
    'Италия': '+39',
    'Испания': '+34',
    'Китай': '+86',
    'Казахстан': '+7',
    'Беларусь': '+375',
    'Украина': '+380',
  };

  @override
  void initState() {
    super.initState();
    _selectedCountry = widget.initialCountry ?? 'Россия';
  }

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<String>(
      value: _selectedCountry,
      decoration: InputDecoration(
        labelText: 'Страна',
        prefixIcon: Icon(Icons.flag),
        border: OutlineInputBorder(),
      ),
      items: _countryCodes.keys.map((String country) {
        return DropdownMenuItem<String>(
          value: country,
          child: Text('$country (${_countryCodes[country]})'),
        );
      }).toList(),
      onChanged: (String? newValue) {
        if (newValue != null) {
          setState(() {
            _selectedCountry = newValue;
          });
          widget.onCountryChanged(newValue, _countryCodes[newValue] ?? '+7');
        }
      },
    );
  }
}
