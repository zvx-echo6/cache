import 'package:flutter/material.dart';

import '../net/web_link.dart';
import '../theme.dart';
import 'emergency_number.dart';

class FirstAidGuide {
  const FirstAidGuide(
    this.title,
    this.subtitle,
    this.emergency,
    this.signs,
    this.actions,
    this.source,
    this.url,
  );

  final String title, subtitle, emergency;
  final List<String> signs, actions;
  final String source, url;
}

const firstAidGuides = <FirstAidGuide>[
  FirstAidGuide(
    'Severe bleeding',
    'Stop the bleeding',
    'Call emergency services for bleeding that is severe or will not stop.',
    [],
    [
      'Press firmly on the wound with clean cloth or gauze.',
      'Keep pressing until the bleeding stops or help arrives.',
      'Add more cloth or gauze on top if blood soaks through. Do not remove the first layer.',
      'Do not remove an object stuck in the wound. Press around it.',
    ],
    'MedlinePlus, National Library of Medicine, First Aid',
    'https://medlineplus.gov/firstaid.html',
  ),
  FirstAidGuide(
    'Stroke',
    'Act F.A.S.T.',
    'Call emergency services immediately if any stroke sign appears suddenly.',
    [
      'Face: Ask the person to smile. Does one side droop?',
      'Arms: Ask the person to raise both arms. Does one drift down?',
      'Speech: Ask for a simple phrase. Is speech slurred or strange?',
      'Other sudden signs include numbness or weakness, confusion, trouble seeing or walking, loss of balance, or a severe headache.',
    ],
    [
      'Call emergency services right away.',
      'Note when the symptoms first appeared.',
      'Use an ambulance. Do not have the person drive.',
      'Call even if the symptoms go away after a few minutes.',
    ],
    'National Institute of Neurological Disorders and Stroke, Signs and Symptoms',
    'https://www.ninds.nih.gov/health-information/stroke/signs-and-symptoms',
  ),
  FirstAidGuide(
    'Heart attack',
    'Signs and what to do',
    'Call emergency services immediately. Do not drive to the hospital.',
    [
      'Chest pain or discomfort that may last more than a few minutes or go away and return.',
      'Pain or discomfort in one or both arms, the back, shoulders, neck, jaw, or upper stomach.',
      'Shortness of breath, with or without chest discomfort.',
      'Unusual tiredness, nausea or vomiting, dizziness, or sweating.',
    ],
    [
      'Call emergency services immediately, even if you are not sure.',
      'Follow the emergency operator\'s instructions.',
      'Use an ambulance. Do not drive yourself or have someone else drive you.',
    ],
    'National Heart, Lung, and Blood Institute, Heart Attack Symptoms',
    'https://www.nhlbi.nih.gov/health/heart-attack/symptoms',
  ),
  FirstAidGuide(
    'Heat illness',
    'Heat exhaustion and heat stroke',
    'Heat stroke is an emergency: Call emergency services for confusion, fainting, strange behavior, dry flushed skin, or a body temperature above 104 F (40 C).',
    [
      'Heat exhaustion: Thirst, dizziness, weakness, poor coordination, nausea, heavy sweating, cold clammy skin, or a rapid pulse.',
    ],
    [
      'Move to a cool place and rest.',
      'Give water or an electrolyte drink if the person can drink safely.',
      'Use cool wet cloths, a cool bath or shower, and fans to lower body temperature.',
      'Get medical care if the person does not improve soon. Call emergency services for signs of heat stroke.',
    ],
    'National Institute on Aging, Hot Weather Safety for Older Adults',
    'https://www.nia.nih.gov/health/safety/hot-weather-safety-older-adults',
  ),
  FirstAidGuide(
    'Poisoning',
    'Get the right help',
    'Call emergency services if the person is unconscious, having trouble breathing, or having seizures.',
    [],
    [
      'In the United States, call Poison Help at 1-800-222-1222.',
      'Do not make the person vomit unless Poison Help or a health professional tells you to.',
      'Follow the instructions from Poison Help or emergency services.',
      'Keep the container or substance information available if it is safe to do so.',
    ],
    'MedlinePlus, National Library of Medicine, Poisoning',
    'https://medlineplus.gov/poisoning.html',
  ),
];

class FirstAidGuideScreen extends StatefulWidget {
  const FirstAidGuideScreen({
    super.key,
    required this.guide,
    this.canCall,
    this.openDialer,
  });
  final FirstAidGuide guide;
  final bool? canCall;
  final Future<bool> Function()? openDialer;

  @override
  State<FirstAidGuideScreen> createState() => _FirstAidGuideScreenState();
}

class _FirstAidGuideScreenState extends State<FirstAidGuideScreen> {
  bool get _canCall => widget.canCall ?? emergencyDialerAvailable;

  Future<void> _call() async {
    final ok = await (widget.openDialer ?? () => openEmergencyDialer())();
    if (!ok && mounted) {
      ScaffoldMessenger.maybeOf(context)
        ?..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text(
              "Couldn't open the phone app. Dial the emergency number yourself.",
            ),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final guide = widget.guide;
    return Scaffold(
      appBar: AppBar(title: Text(guide.title)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          if (_canCall)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: SizedBox(
                height: 68,
                child: FilledButton.icon(
                  key: const ValueKey('guide-call'),
                  style: FilledButton.styleFrom(
                    backgroundColor: k.emergency,
                    foregroundColor: Colors.white,
                    textStyle: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  onPressed: _call,
                  icon: const Icon(Icons.call, size: 28),
                  label: const Text('Call emergency services'),
                ),
              ),
            ),
          _card(
            context,
            Text(
              guide.emergency,
              style: TextStyle(
                color: k.emergency,
                fontWeight: FontWeight.w700,
                fontSize: 16,
                height: 1.4,
              ),
            ),
          ),
          if (guide.signs.isNotEmpty) ...[
            _heading(context, 'Signs'),
            _card(
              context,
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final sign in guide.signs)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        sign,
                        style: TextStyle(
                          color: k.text,
                          fontSize: 16,
                          height: 1.35,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
          _heading(context, 'What to do'),
          _card(
            context,
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < guide.actions.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      '${i + 1}. ${guide.actions[i]}',
                      style: TextStyle(
                        color: k.text,
                        fontSize: 16,
                        height: 1.35,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          _GuideSource(guide: guide),
        ],
      ),
    );
  }

  Widget _heading(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.fromLTRB(2, 20, 2, 8),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w700,
        color: context.t.text,
      ),
    ),
  );
  Widget _card(BuildContext context, Widget child) => Card(
    margin: EdgeInsets.zero,
    child: Padding(padding: const EdgeInsets.all(16), child: child),
  );
}

class _GuideSource extends StatelessWidget {
  const _GuideSource({required this.guide});
  final FirstAidGuide guide;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: InkWell(
      key: const ValueKey('guide-source'),
      onTap: () => openWebLink(context, guide.url),
      child: Text(
        'Source: ${guide.source}',
        style: TextStyle(fontSize: 13, color: context.t.secondary),
      ),
    ),
  );
}
